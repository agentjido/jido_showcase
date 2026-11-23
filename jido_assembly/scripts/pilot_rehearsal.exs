defmodule Jido.Assembly.PilotRehearsal do
  @moduledoc false

  import ExUnit.Assertions

  alias Jido.Assembly.{
    Bridges,
    Chat,
    ChatRuntime,
    ChatStorage,
    Pilot,
    PilotSessions,
    ScriptedInference
  }

  @team_size 25
  @general "room:general"
  @ada "user:member1"
  @lee "user:member2"
  @interval_ms 100

  def run do
    directory =
      Path.join(
        System.tmp_dir!(),
        "assembly-pilot-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(directory)
    rehearse(directory)
  after
    Application.stop(:jido_assembly)
  end

  defp rehearse(directory) do
    roster = Path.join(directory, "roster.json")
    database = Path.join(directory, "team.sqlite3")
    write_roster(roster, @team_size)

    Application.put_env(:jido_assembly, :pilot_roster, roster)
    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)
    start(database)

    assert Pilot.enabled?()
    assert :disabled = Bridges.setup_status()
    assert {:ok, [general]} = ChatRuntime.list_rooms()
    assert general.id == @general
    assert {:ok, []} = ChatRuntime.list_room_history(@general)
    assert {:ok, %{status: :active}} = ChatRuntime.get_room_membership(@general, @lee)
    IO.puts("Fresh pilot has one shared channel, no demo messages, and active team membership.")

    assert %{demo_users: [], current_user: %{name: "Member 1"}} = Chat.snapshot(@ada, @general)
    assert {:ok, room, _messages} = Chat.create_channel(%{name: "pilot-rehearsal"})
    assert {:ok, root} = Chat.send_message(room.id, "Check rollout in this thread.", @ada)

    assert {:ok, reply} =
             Chat.send_message(room.id, "Rollout checklist complete.", @lee, thread_id: root.id)

    assert {:ok, _message} = Chat.toggle_reaction(root.id, "👍", @lee)

    assert [%{message_id: reply_id, thread_id: root_id}] = Chat.search("checklist complete", @ada)
    assert {reply_id, root_id} == {reply.id, root.id}
    assert {:ok, _post} = Chat.send_message(room.id, "@triage pilot agent is off", @ada)
    assert {:ok, []} = ChatStorage.list_agent_runs(room.id)
    IO.puts("Two users posted, replied, reacted, and searched. Disabled agents queued no work.")

    :ok = PilotSessions.open("rehearsal-session", @ada)
    :ok = Application.stop(:jido_assembly)
    backup = Path.join(directory, "restored.sqlite3")
    File.cp!(database, backup)
    write_roster(roster, @team_size + 1)
    start(backup)

    refute PilotSessions.valid?("rehearsal-session", @ada)
    assert {:ok, restored_root} = ChatRuntime.get_room_history(room.id, root.id)
    assert {:ok, restored_reply} = ChatRuntime.get_room_history(room.id, reply.id)
    assert restored_root.message_id == root.id
    assert restored_reply.message_id == reply.id
    assert restored_reply.thread_id == root.id
    assert {:ok, %{status: :active}} = ChatRuntime.get_room_reaction(room.id, root.id, "👍", @lee)

    newcomer = "user:member#{@team_size + 1}"
    assert {:ok, %{status: :active}} = ChatRuntime.get_room_membership(room.id, newcomer)

    IO.puts(
      "Restored backup kept message IDs, the thread, and the reaction. A new member can join existing channels."
    )

    rehearse_agent(room.id, root.id)
    if "--load" in System.argv(), do: load()
  after
    Application.stop(:jido_assembly)
    File.rm_rf!(directory)
  end

  defp rehearse_agent(room, root) do
    answer = "Record the approved rollout in the release log."

    {:ok, supervisor} =
      Supervisor.start_link([{ScriptedInference, [answer]}], strategy: :one_for_one)

    Application.put_env(:jido_assembly, :agent_trigger_options,
      enabled: true,
      inference_client: ScriptedInference
    )

    assert {:ok, trigger} =
             Chat.send_message(room, "@triage check this rollout.", @lee, thread_id: root)

    trigger_id = trigger.id
    assert %{trigger_id: ^trigger_id, thread_id: ^root} = await_run(room, trigger_id, 50)
    assert [_call] = ScriptedInference.calls()

    assert Enum.any?(Chat.list_thread_views(room, root, @ada), fn reply ->
             reply.reply_to_id == trigger_id and reply.body == answer
           end)

    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)
    Supervisor.stop(supervisor)
    IO.puts("A configured Triage agent used scripted inference and replied to the exact trigger.")
  end

  defp await_run(_room, _id, 0), do: flunk("The pilot Triage run did not complete.")

  defp await_run(room, id, attempts) do
    assert {:ok, runs} = ChatStorage.list_agent_runs(room)

    case Enum.find(runs, &(&1.trigger_id == id and &1.status == "completed")) do
      nil ->
        Process.sleep(100)
        await_run(room, id, attempts - 1)

      run ->
        run
    end
  end

  defp load do
    seconds = String.to_integer(System.get_env("ASSEMBLY_PILOT_LOAD_SECONDS", "10"))
    assert seconds in 1..60, "Use a test duration from 1 to 60 seconds per workload."

    rooms =
      for index <- 1..5 do
        {:ok, room, _messages} = Chat.create_channel(%{name: "pilot-load-#{index}"})
        room.id
      end

    count = seconds * div(1_000, @interval_ms)
    IO.inspect(measure("one_room", Enum.take(rooms, 1), count), label: "runtime SQLite load")
    IO.inspect(measure("five_rooms", rooms, count), label: "runtime SQLite load")
  end

  defp measure(label, rooms, count) do
    started = System.monotonic_time(:millisecond) + 100

    tasks =
      for index <- 0..(count - 1) do
        room = Enum.at(rooms, rem(index, length(rooms)))
        user = "user:member#{rem(index, @team_size) + 1}"
        scheduled = started + index * @interval_ms

        Task.async(fn ->
          Process.sleep(max(0, scheduled - System.monotonic_time(:millisecond)))
          lag = System.monotonic_time(:millisecond) - scheduled

          {elapsed, {:ok, message}} =
            :timer.tc(fn -> Chat.send_message(room, "Pilot load #{label} #{index}", user) end)

          %{id: message.id, room: room, elapsed: elapsed, lag: lag}
        end)
      end

    results = Task.await_many(tasks, count * @interval_ms + 20_000)
    assert length(Enum.uniq_by(results, & &1.id)) == count

    for {room, posts} <- Enum.group_by(results, & &1.room) do
      {:ok, history} = ChatRuntime.list_room_history(room, limit: 1_000)
      sequences = Enum.map(history, & &1.sequence)
      assert sequences == Enum.sort(Enum.uniq(sequences))
      stored = MapSet.new(history, & &1.message_id)
      assert Enum.all?(posts, &MapSet.member?(stored, &1.id))
    end

    latencies = results |> Enum.map(& &1.elapsed) |> Enum.sort()

    %{
      workload: label,
      posts: count,
      p95_ms: percentile(latencies, 0.95),
      p99_ms: percentile(latencies, 0.99),
      max_start_lag_ms: results |> Enum.map(& &1.lag) |> Enum.max()
    }
  end

  defp percentile(values, fraction) do
    index = ceil(length(values) * fraction) - 1
    Float.round(Enum.at(values, index) / 1_000, 2)
  end

  defp start(database) do
    Application.put_env(:jido_assembly, :sqlite_path, database)
    assert {:ok, _apps} = Application.ensure_all_started(:jido_assembly)
  end

  defp write_roster(path, count) do
    entries =
      for index <- 1..count do
        %{
          id: "user:member#{index}",
          name: "Member #{index}",
          key_sha256: Base.encode16(:crypto.strong_rand_bytes(32))
        }
      end

    File.write!(path, Jason.encode!(entries))
  end
end

if Mix.env() != :test or Process.whereis(Jido.Assembly.ChatStorage) do
  raise "Run with MIX_ENV=test and mix run --no-start."
end

Jido.Assembly.PilotRehearsal.run()
