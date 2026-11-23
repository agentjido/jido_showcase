defmodule Jido.Assembly.Presence do
  @moduledoc """
  Assembly-owned online session service.

  Durable Room membership and online presence are separate. Each browser
  session has one supervised Phoenix Presence tracker and one bounded TTL.
  """

  use GenServer

  alias Jido.Assembly.Presence.{Session, SessionSupervisor}
  alias Jido.Assembly.Seeds

  @heartbeat_interval_ms 15_000
  @session_ttl_ms 45_000
  @prune_interval_ms 5_000

  @doc "Starts the online session service."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the browser heartbeat interval."
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @doc "Returns the current online projection."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Returns true when at least one session for the user is online."
  def online?(user_id), do: user_id in snapshot().online_user_ids

  @doc "Creates or refreshes one browser session."
  def touch(user_id, room_id, opts \\ []) do
    GenServer.call(__MODULE__, {:touch, user_id, room_id, opts})
  end

  @doc "Ends all sessions for one user, or one session when :session_id is given."
  def mark_left(user_id, opts \\ []), do: GenServer.call(__MODULE__, {:mark_left, user_id, opts})

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  def presence_topic, do: "assembly:presence:#{Seeds.workspace_id()}"

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, project(state), state}

  def handle_call({:touch, user_id, room_id, opts}, _from, state) do
    session_id = Keyword.get(opts, :session_id, "session:#{user_id}")
    ttl_ms = Keyword.get(opts, :ttl_ms, @session_ttl_ms)

    cond do
      not valid_id?(user_id) or not valid_id?(room_id) or not valid_id?(session_id) ->
        {:reply, {:error, :invalid_presence}, state}

      not is_integer(ttl_ms) or ttl_ms <= 0 ->
        {:reply, {:error, :invalid_presence_ttl}, state}

      true ->
        online_before = online_user_ids(state)

        case put_session(state, session_id, user_id, room_id, ttl_ms) do
          {:ok, next} ->
            signals = transition_signals(user_id, room_id, online_before)
            presence = project(next)
            notify(:touch, presence, signals)
            {:reply, {:ok, presence, signals}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:mark_left, user_id, opts}, _from, state) do
    online_before = online_user_ids(state)
    session_id = Keyword.get(opts, :session_id)

    {removed, kept} =
      Enum.split_with(state.sessions, fn {id, session} ->
        session.user_id == user_id and (is_nil(session_id) or id == session_id)
      end)

    Enum.each(removed, fn {_id, session} -> stop_session(session.pid) end)
    next = %{state | sessions: Map.new(kept)}
    signals = leave_signals(user_id, online_before, online_user_ids(next))
    presence = project(next)
    notify(:leave, presence, signals)
    {:reply, {:ok, presence, signals}, next}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.sessions, fn {_id, session} -> stop_session(session.pid) end)
    {:reply, :ok, %{state | sessions: %{}}}
  end

  @impl true
  def handle_info(:prune, state) do
    now = now_ms()

    {expired, active} =
      Enum.split_with(state.sessions, fn {_id, session} -> session.expires_at_ms <= now end)

    online_before = online_user_ids(state)
    Enum.each(expired, fn {_id, session} -> stop_session(session.pid) end)
    next = %{state | sessions: Map.new(active)}
    online_after = online_user_ids(next)

    signals =
      expired
      |> Enum.map(fn {_id, session} -> session.user_id end)
      |> Enum.uniq()
      |> Enum.flat_map(&leave_signals(&1, online_before, online_after))

    if signals != [], do: notify(:expired, project(next), signals)
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, next}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    sessions = Map.reject(state.sessions, fn {_id, session} -> session.pid == pid end)
    {:noreply, %{state | sessions: sessions}}
  end

  defp put_session(state, session_id, user_id, room_id, ttl_ms) do
    expires_at_ms = now_ms() + ttl_ms
    metadata = %{session_id: session_id, room_id: room_id, expires_at_ms: expires_at_ms}

    case Map.get(state.sessions, session_id) do
      %{user_id: ^user_id, pid: pid} = current ->
        with :ok <- Session.update(pid, metadata) do
          next = %{current | room_id: room_id, expires_at_ms: expires_at_ms}
          {:ok, put_in(state.sessions[session_id], next)}
        end

      nil ->
        start_session(state, session_id, user_id, room_id, expires_at_ms, metadata)

      current ->
        stop_session(current.pid)
        state = update_in(state.sessions, &Map.delete(&1, session_id))
        start_session(state, session_id, user_id, room_id, expires_at_ms, metadata)
    end
  end

  defp start_session(state, session_id, user_id, room_id, expires_at_ms, metadata) do
    opts = [session_id: session_id, topic: presence_topic(), user_id: user_id, metadata: metadata]

    case DynamicSupervisor.start_child(SessionSupervisor, {Session, opts}) do
      {:ok, pid} ->
        Process.link(pid)

        session = %{
          pid: pid,
          session_id: session_id,
          user_id: user_id,
          room_id: room_id,
          expires_at_ms: expires_at_ms
        }

        {:ok, put_in(state.sessions[session_id], session)}

      {:error, reason} ->
        {:error, {:presence_track_failed, reason}}
    end
  end

  defp transition_signals(user_id, room_id, before) do
    if user_id in before do
      []
    else
      [
        signal("jido.assembly.presence.joined", user_id, room_id, %{state: "online"}),
        signal("jido.assembly.presence.changed", user_id, room_id, %{
          from: "offline",
          to: "online"
        })
      ]
    end
  end

  defp leave_signals(user_id, before, after_ids) do
    if user_id in before and user_id not in after_ids do
      [
        signal("jido.assembly.presence.left", user_id, nil, %{state: "offline"}),
        signal("jido.assembly.presence.changed", user_id, nil, %{from: "online", to: "offline"})
      ]
    else
      []
    end
  end

  defp signal(type, user_id, room_id, data) do
    Jido.Signal.new!(type, Map.merge(data, %{user_id: user_id, room_id: room_id}),
      source: "/jido-assembly/presence"
    )
  end

  defp project(state) do
    %{
      online_user_ids: online_user_ids(state),
      sessions:
        state.sessions
        |> Map.values()
        |> Enum.map(&Map.drop(&1, [:pid]))
        |> Enum.sort_by(& &1.session_id)
    }
  end

  defp online_user_ids(state) do
    state.sessions
    |> Map.values()
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stop_session(pid) do
    case DynamicSupervisor.terminate_child(SessionSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp notify(event, presence, signals),
    do: Jido.AssemblyWeb.PresenceNotifier.notify(event, presence, signals)

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..256
  defp now_ms, do: System.monotonic_time(:millisecond)
end
