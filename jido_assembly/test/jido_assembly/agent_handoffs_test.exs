defmodule Jido.Assembly.AgentHandoffsTest do
  use Jido.Assembly.HologramPageCase, async: false

  alias Hologram.Server.Broadcast
  alias Hologram.Template.Renderer
  alias Hologram.Template.Renderer.Env

  alias Jido.Assembly.{
    AgentRuns,
    Agents,
    Chat,
    ChatRuntime,
    ChatStorage,
    ReleaseNotes,
    ScriptedInference,
    Seeds
  }

  alias Jido.Assembly.Agents.Actions.{PublishReleaseNote, ReadReleaseEvidence}
  alias Jido.Assembly.Components.Assembly.ThreadPanel
  alias Jido.Assembly.Pages.Assembly
  alias Jido.Assembly.ReleaseNotes.Publication
  alias Jido.Assembly.ReleaseNotes.Workflow

  @maya "user:maya"
  @eli "user:eli"
  @supervisor Jido.Assembly.Supervisor

  setup do
    previous = Application.fetch_env!(:jido_assembly, :agent_trigger_options)
    on_exit(fn -> Application.put_env(:jido_assembly, :agent_trigger_options, previous) end)

    Application.put_env(:jido_assembly, :agent_trigger_options,
      enabled: false,
      release_delegation: true
    )

    %{room: Seeds.release_room_id()}
  end

  @tag scenario: "JA01"
  test "Triage delegates two scoped runs from the release request after a restart", %{room: room} do
    request = "@triage check delivery and rollout for release JA01."
    trigger = compose!(room, request)
    root = trigger.id

    assert [%{id: parent, scope: "release_plan", parent_run_id: nil, status: "queued"}] =
             runs_for!(room, root)

    assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
    on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)

    start_turns!([
      "Check both release risks.",
      {:object, delivery("pending", "Check delivery receipts.", [root])},
      "Verify rollout owners.",
      "Check delivery receipts and confirm rollout owners."
    ])

    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)

    assert [
             %{id: ^parent, agent_id: "agent:triage"},
             %{
               id: bridge,
               agent_id: "agent:bridge",
               scope: "provider_delivery",
               parent_run_id: ^parent
             },
             %{
               id: runbook,
               agent_id: "agent:runbook",
               scope: "impact_and_rollout",
               parent_run_id: ^parent
             },
             %{scope: "release_synthesis", parent_run_id: ^parent}
           ] = runs = await_completed!(room, root)

    assert length(Enum.uniq([parent, bridge, runbook])) == 3

    assert Enum.all?(
             runs,
             &(&1.room_id == room and &1.trigger_id == root and &1.thread_id == root)
           )

    assert {:ok, path} = ChatStorage.path()

    reopened =
      start_supervised!({ChatStorage, id: :handoff_reader, name: __MODULE__.Reader, path: path})

    assert {:ok, reopened_runs} = ChatStorage.list_agent_runs(reopened, room)
    assert Enum.filter(reopened_runs, &(&1.trigger_id == root)) == runs

    assert [triage_call, bridge_call, runbook_call, _synthesis_call] =
             Enum.map(ScriptedInference.calls(), &input/1)

    assert triage_call =~ request
    assert triage_call =~ "Run ID: #{parent}"
    assert bridge_call =~ "Run ID: #{bridge}"
    assert bridge_call =~ "Check provider delivery routes, receipts, and pending checks."
    assert runbook_call =~ "Run ID: #{runbook}"
    assert runbook_call =~ "Check customer impact, rollout steps, and required approvals."

    for call <- [bridge_call, runbook_call] do
      assert call =~ "Parent run ID: #{parent}"
      assert call =~ request
    end

    for run <- runs do
      reply_id = AgentRuns.reply_id(run.id)
      reply_to = if run.id == parent, do: root, else: AgentRuns.reply_id(parent)

      assert {:ok, %{thread_id: ^root, reply_to_id: ^reply_to} = reply} =
               Chat.get_message_view(reply_id)

      assert reply.sender_id == run.agent_id
      assert reply.metadata["agent_run_id"] == run.id
      assert reply.metadata["agent_parent_run_id"] == run.parent_run_id
      assert reply.metadata["agent_scope"] == run.scope
    end

    finish_review!(root)
  end

  for decision <- ["stage_publication", "hold"] do
    test "saves a #{decision} recommendation without writing to the release log", %{room: room} do
      decision = unquote(decision)
      options = Application.fetch_env!(:jido_assembly, :agent_trigger_options)

      Application.put_env(
        :jido_assembly,
        :agent_trigger_options,
        Keyword.put(options, :release_publication_recommendation, true)
      )

      root = compose!(room, "@triage check whether this note is ready for review.").id
      receipt = "QA verified receipt REVIEW-042."

      assert {:ok, _evidence} =
               Chat.send_message(
                 room,
                 receipt <> " " <> String.duplicate("Extra test details. ", 22),
                 @eli,
                 thread_id: root,
                 reply_to_id: root
               )

      destination = Seeds.release_log_room_id()
      assert {:ok, original_history} = ChatRuntime.list_room_history(destination)

      start_turns!([
        "Check the evidence first.",
        {:object, delivery("pending", "The provider receipt is missing.", [root])},
        "Confirm the rollout owner.",
        {:object, %{"summary" => "Confirm the rollout owner.", "next_step" => decision}}
      ])

      runs = await_completed!(room, root)
      synthesis = Enum.find(runs, &(&1.scope == "release_synthesis"))

      assert {:ok,
              %{
                thread_id: ^root,
                metadata: %{"agent_result" => %{"publication_recommendation" => recommendation}}
              }} = Chat.get_message_view(AgentRuns.reply_id(synthesis.id), @maya)

      expected = %{"decision" => decision}

      expected =
        if decision == "stage_publication" do
          Map.merge(expected, %{"action" => Publication.action(), "destination_id" => destination})
        else
          expected
        end

      assert recommendation == expected
      assert {:ok, ^original_history} = ChatRuntime.list_room_history(destination)

      synthesis_input = ScriptedInference.calls() |> List.last() |> input()
      assert synthesis_input =~ receipt
      assert String.length(synthesis_input) <= 2_000

      finish_review!(root)
    end
  end

  @tag scenario: "JA02"
  test "Runbook receives the saved Bridge finding and its exact thread sources", %{room: room} do
    root = compose!(room, "@triage check the delivery receipt for release JA02.").id
    receipt = "The fixture delivered the candidate to the Discord test room. Receipt D-042."

    assert {:ok, evidence} =
             Chat.send_message(room, receipt, "user:eli", thread_id: root, reply_to_id: root)

    assert {:ok, _sibling} = Chat.send_message(room, "Unrelated receipt U-091.", "user:eli")

    source_id = evidence.id
    result = delivery("confirmed", "The Discord test-room receipt is D-042.", [root, source_id])

    start_turns!([
      "Check the Discord test-room receipt.",
      {:object, result},
      "Keep the Discord receipt in the rollout record.",
      "Record the Discord receipt with the rollout checks."
    ])

    assert [_, %{id: bridge_id, result: ^result}, _, _] = runs = await_completed!(room, root)
    bridge_reply = AgentRuns.reply_id(bridge_id)
    assert {:ok, finding} = Chat.get_message_view(bridge_reply)
    assert finding.metadata["agent_result"] == result
    assert finding.body == result["summary"]

    assert {:ok, path} = ChatStorage.path()

    reopened =
      start_supervised!({ChatStorage, id: :handoff_reader, name: __MODULE__.Reader, path: path})

    assert {:ok, stored_runs} = ChatStorage.list_agent_runs(reopened, room)
    assert Enum.filter(stored_runs, &(&1.trigger_id == root)) == runs

    assert [_, bridge_call, runbook_call, _] = ScriptedInference.calls()
    assert Keyword.fetch!(bridge_call.options, :output_validation) == :strict
    assert input(bridge_call) =~ receipt
    refute input(bridge_call) =~ "U-091"

    line =
      runbook_call
      |> input()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "Bridge delivery finding (#{bridge_reply}): "))

    assert "Bridge delivery finding (" <> _ = line
    assert line |> String.split("): ", parts: 2) |> List.last() |> Jason.decode!() == result
    refute input(runbook_call) =~ "U-091"

    {page, server} =
      init_page(Assembly, %{},
        user_id: @maya,
        query: %{"room" => room, "message" => bridge_reply}
      )

    {html, _, _} =
      Renderer.render_dom(
        ThreadPanel.template().(Map.put(page.state, :mobile, false)),
        %Env{},
        server
      )

    links =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(
        ~s([data-assembly-message-id="#{bridge_reply}"] [data-assembly-source-id="#{source_id}"])
      )
      |> LazyHTML.attribute("href")

    assert [href | _] = links
    assert Enum.uniq(links) == [evidence.permalink]
    query = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {opened, _} = init_page(Assembly, %{}, user_id: @maya, query: query)
    assert %{thread_root: %{id: ^root}, focused_message_id: ^source_id} = opened.state

    finish_review!(root)
  end

  @tag scenario: "JA03"
  test "malformed findings and foreign citations stop before the Runbook model call", %{
    room: room
  } do
    wrong_type = compose!(room, "@triage check the delivery fields for JA03.").id
    foreign_citation = compose!(room, "@triage check the delivery citations for JA03.", @eli).id

    assert {:ok, foreign} =
             Chat.send_message(room, "A receipt from the other release.", @maya,
               thread_id: wrong_type,
               reply_to_id: wrong_type
             )

    malformed = delivery("pending", "Invalid source value.", wrong_type)
    cross_thread = delivery("confirmed", "This receipt belongs to another request.", [foreign.id])

    start_turns!(fn call ->
      text = input(call)

      cond do
        text =~ "Scope: Identify evidence needs" -> "Inspect the delivery evidence."
        text =~ "delivery fields for JA03" -> {:object, malformed}
        text =~ "delivery citations for JA03" -> {:object, cross_thread}
        true -> nil
      end
    end)

    histories =
      for root <- [wrong_type, foreign_citation] do
        assert [
                 _,
                 %{error: "invalid_delivery_finding", result: nil} = bridge,
                 %{error: "delivery_finding_unavailable", result: nil} = runbook,
                 %{error: "required_findings_unavailable"}
               ] =
                 await_runs!(room, root, List.duplicate("failed", 4))

        replies = Chat.list_thread_views(room, root, @maya)

        for {run, text} <- [
              {bridge, "Bridge returned an invalid delivery finding"},
              {runbook, "Runbook stopped because it needs a valid Bridge delivery finding"}
            ] do
          reply_id = AgentRuns.reply_id(run.id)

          assert [%{body: body, metadata: metadata, agent_sources: []}] =
                   Enum.filter(replies, &(&1.id == reply_id))

          assert body =~ text
          assert metadata["agent_error"] == run.error
          refute Map.has_key?(metadata, "agent_result")
        end

        {root, replies}
      end

    assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
    on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)

    for {root, replies} <- histories do
      assert Chat.list_thread_views(room, root, @maya) == replies
    end

    calls = Enum.map(ScriptedInference.calls(), &input/1)
    assert length(calls) == 4
    refute Enum.any?(calls, &String.contains?(&1, "Scope: Check customer impact"))

    assert [_, _] = bridge_calls = Enum.filter(calls, &String.contains?(&1, "Thread evidence:"))
    first_bridge = Enum.find(bridge_calls, &String.contains?(&1, "delivery fields for JA03"))
    second_bridge = Enum.find(bridge_calls, &String.contains?(&1, "delivery citations for JA03"))

    assert first_bridge =~ foreign.id
    refute second_bridge =~ foreign.id

    finish_review!(wrong_type)
    finish_review!(foreign_citation, "eli")
  end

  @tag scenario: "JA04"
  test "Triage waits for both findings and saves one synthesis in either order", %{room: room} do
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    for {first, second} <- [{:bridge, :runbook}, {:runbook, :bridge}] do
      Application.put_env(:jido_assembly, :agent_trigger_options,
        enabled: false,
        release_delegation: true,
        release_peer_context: false
      )

      root = compose!(room, "@triage verify delivery and rollout for JA04.").id
      assert [%{id: parent_id, peer_context: false}] = runs_for!(room, root)

      [bridge_reply, runbook_reply] =
        Enum.map(AgentRuns.finding_run_ids(parent_id), &AgentRuns.reply_id/1)

      source_ids = [bridge_reply, runbook_reply]

      synthesis_id =
        parent_id |> AgentRuns.handoff_id("release_synthesis") |> AgentRuns.reply_id()

      reply_ids = %{bridge: bridge_reply, runbook: runbook_reply}
      first_id = Map.fetch!(reply_ids, first)
      second_id = Map.fetch!(reply_ids, second)

      test = self()

      start_turns!(fn call ->
        case scope(call) do
          "release_plan" ->
            "Check delivery and rollout."

          "provider_delivery" ->
            hold_finding(
              test,
              :bridge,
              {:object, delivery("pending", "Delivery is pending.", [root])}
            )

          "impact_and_rollout" ->
            hold_finding(test, :runbook, "Confirm the owner before rollout.")

          "release_synthesis" ->
            "Confirm delivery and the rollout owner before release."
        end
      end)

      assert_receive {:finding_started, ^first, first_pid}, 3_000
      assert_receive {:finding_started, ^second, second_pid}, 3_000
      send(first_pid, :finish_finding)
      assert_receive {:signal, %Jido.Signal{id: ^first_id}}, 3_000

      assert [%{status: "waiting"}, _, _] = runs_for!(room, root)
      assert {:ok, nil} = ChatRuntime.get_room_history(room, synthesis_id)
      refute Enum.any?(ScriptedInference.calls(), &(scope(&1) == "release_synthesis"))

      opts = Application.fetch_env!(:jido_assembly, :agent_trigger_options)

      Application.put_env(
        :jido_assembly,
        :agent_trigger_options,
        Keyword.put(opts, :enabled, false)
      )

      send(second_pid, :finish_finding)

      statuses =
        if first == :bridge,
          do: ["waiting", "completed", "ready"],
          else: ["waiting", "ready", "completed"]

      await_runs!(room, root, statuses)
      assert {:ok, nil} = ChatRuntime.get_room_history(room, second_id)

      assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
      on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)
      Application.put_env(:jido_assembly, :agent_trigger_options, opts)
      assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)

      assert_receive {:signal, %Jido.Signal{id: ^second_id}}, 3_000
      assert_receive {:signal, %Jido.Signal{id: ^synthesis_id}}, 3_000

      assert [%{id: ^parent_id}, _, _, %{result: %{"source_message_ids" => ^source_ids}}] =
               runs = await_completed!(room, root)

      assert {:ok, %{thread_id: ^root, agent_sources: sources}} =
               Chat.get_message_view(synthesis_id)

      assert Enum.map(sources, & &1.id) == source_ids

      for source <- sources do
        assert {:ok, referenced} = Chat.get_message_view(source.id)
        assert referenced.thread_id == root
        assert referenced.permalink == source.href
      end

      calls = ScriptedInference.calls()
      assert [synthesis_call] = Enum.filter(calls, &(scope(&1) == "release_synthesis"))
      assert input(synthesis_call) =~ bridge_reply
      assert input(synthesis_call) =~ "Delivery is pending."
      assert input(synthesis_call) =~ runbook_reply
      assert input(synthesis_call) =~ "Confirm the owner before rollout."

      assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
      on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)
      assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)
      refute_receive {:signal, %Jido.Signal{id: ^synthesis_id}}, 250
      assert ScriptedInference.calls() == calls
      assert runs_for!(room, root) == runs

      finish_review!(root)
      stop_supervised!(ScriptedInference)
    end
  end

  @tag scenario: "JA05"
  test "findings from parallel release requests cannot satisfy each other's synthesis", %{
    room: room
  } do
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    Application.put_env(:jido_assembly, :agent_trigger_options,
      enabled: false,
      release_delegation: true,
      release_peer_context: false
    )

    roots = %{
      maya: compose!(room, "@triage check Maya's candidate JA05-MAYA.").id,
      eli: compose!(room, "@triage check Eli's candidate JA05-ELI.", @eli).id
    }

    replies =
      Map.new(roots, fn {person, root} ->
        assert [%{id: parent}] = runs_for!(room, root)
        [bridge, runbook] = Enum.map(AgentRuns.finding_run_ids(parent), &AgentRuns.reply_id/1)
        synthesis = parent |> AgentRuns.handoff_id("release_synthesis") |> AgentRuns.reply_id()
        {person, %{bridge: bridge, runbook: runbook, synthesis: synthesis}}
      end)

    evidence = %{
      maya: %{delivery: "MAYA-RECEIPT-941", rollout: "MAYA-ROLLOUT-812", marker: "JA05-MAYA"},
      eli: %{delivery: "ELI-RECEIPT-349", rollout: "ELI-ROLLOUT-218", marker: "JA05-ELI"}
    }

    test = self()

    start_turns!(fn call ->
      {person, finding} = Enum.find(evidence, fn {_, item} -> input(call) =~ item.marker end)

      case {person, scope(call)} do
        {_, "release_plan"} ->
          "Check both findings."

        {:eli, "provider_delivery"} ->
          response = {:object, delivery("pending", finding.delivery, [roots.eli])}
          hold_finding(test, :eli_bridge, response)

        {:maya, "provider_delivery"} ->
          {:object, delivery("pending", finding.delivery, [roots.maya])}

        {:maya, "impact_and_rollout"} ->
          hold_finding(test, :maya_runbook, finding.rollout)

        {:eli, "impact_and_rollout"} ->
          finding.rollout

        {_, "release_synthesis"} ->
          "Keep the delivery receipt and rollout check in this release record."
      end
    end)

    maya_synthesis = replies.maya.synthesis
    eli_synthesis = replies.eli.synthesis
    maya_bridge = replies.maya.bridge
    eli_runbook = replies.eli.runbook
    assert_receive {:finding_started, :maya_runbook, maya_pending}, 3_000
    assert_receive {:finding_started, :eli_bridge, eli_pending}, 3_000
    assert_receive {:signal, %Jido.Signal{id: ^maya_bridge}}, 3_000
    assert_receive {:signal, %Jido.Signal{id: ^eli_runbook}}, 3_000

    assert [%{status: "waiting"}, %{status: "completed"}, %{status: "running"}] =
             runs_for!(room, roots.maya)

    assert [%{status: "waiting"}, %{status: "running"}, %{status: "completed"}] =
             runs_for!(room, roots.eli)

    refute Enum.any?(ScriptedInference.calls(), &(scope(&1) == "release_synthesis"))

    send(eli_pending, :finish_finding)
    assert_receive {:signal, %Jido.Signal{id: ^eli_synthesis}}, 3_000
    assert {:ok, nil} = ChatRuntime.get_room_history(room, maya_synthesis)
    assert [%{status: "waiting"}, _, _] = runs_for!(room, roots.maya)

    send(maya_pending, :finish_finding)
    assert_receive {:signal, %Jido.Signal{id: ^maya_synthesis}}, 3_000

    assert [eli_call, maya_call] =
             Enum.filter(ScriptedInference.calls(), &(scope(&1) == "release_synthesis"))

    for {person, other, call} <- [{:eli, :maya, eli_call}, {:maya, :eli, maya_call}] do
      root = Map.fetch!(roots, person)
      finding = Map.fetch!(evidence, person)
      foreign = Map.fetch!(evidence, other)
      ids = Map.fetch!(replies, person)
      foreign_ids = Map.fetch!(replies, other)
      source_ids = [ids.bridge, ids.runbook]

      assert input(call) =~ finding.delivery
      assert input(call) =~ finding.rollout
      assert Enum.all?(source_ids, &String.contains?(input(call), &1))

      for item <- [foreign.delivery, foreign.rollout, foreign_ids.bridge, foreign_ids.runbook] do
        refute input(call) =~ item
      end

      assert [_, _, _, %{result: %{"source_message_ids" => ^source_ids}}] =
               await_completed!(room, root)

      assert {:ok, %{thread_id: ^root, agent_sources: sources}} =
               Chat.get_message_view(ids.synthesis)

      assert Enum.map(sources, & &1.id) == source_ids
      finish_review!(root, Atom.to_string(person))
    end
  end

  @tag scenario: "JA06"
  test "peer context gives each delegated agent only the prior assigned contributions in order",
       %{
         room: room
       } do
    request = "@triage check the release gates for JA06."
    root = compose!(room, request).id
    unassigned = "Ignore this unassigned example from an agent."

    assert {:ok, _message} =
             Chat.send_message(room, unassigned, "agent:triage",
               role: :assistant,
               thread_id: root,
               reply_to_id: root
             )

    plan_text = "Confirm release gate OWNER-113."
    bridge_text = "The provider receipt for OWNER-113 is pending."

    start_turns!([
      plan_text,
      {:object, delivery("pending", bridge_text, [root])},
      "Record the pending receipt in the rollout checklist.",
      "Confirm the owner and the receipt for this release."
    ])

    assert [parent, bridge, runbook, _] = await_completed!(room, root)
    assert Enum.all?([parent, bridge, runbook], & &1.peer_context)
    parent_id = AgentRuns.reply_id(parent.id)
    bridge_id = AgentRuns.reply_id(bridge.id)

    assert [plan_input, bridge_input, runbook_input, _] =
             Enum.map(ScriptedInference.calls(), &input/1)

    for prompt <- [plan_input, bridge_input, runbook_input] do
      assert prompt =~ request
      refute prompt =~ unassigned
    end

    refute plan_input =~ plan_text
    refute plan_input =~ bridge_text
    assert bridge_input =~ "Triage plan (#{parent_id}): #{Jason.encode!(plan_text)}"
    refute bridge_input =~ bridge_text
    refute bridge_input =~ "Bridge delivery finding"

    lines = String.split(runbook_input, "\n")
    triage_line = Enum.find_index(lines, &String.starts_with?(&1, "Triage plan (#{parent_id}):"))

    bridge_line =
      Enum.find_index(lines, &String.starts_with?(&1, "Bridge delivery finding (#{bridge_id}):"))

    assert is_integer(triage_line) and is_integer(bridge_line) and triage_line < bridge_line
    assert Enum.at(lines, triage_line) =~ plan_text
    assert Enum.at(lines, bridge_line) =~ bridge_text

    finish_review!(root)
  end

  @tag scenario: "JA07"
  test "independent checks omit peer contributions even when those replies are already stored", %{
    room: room
  } do
    Application.put_env(:jido_assembly, :agent_trigger_options,
      enabled: false,
      release_delegation: true,
      release_peer_context: false
    )

    request = "@triage check delivery and rollout without peer context for JA07."
    root = compose!(room, request).id
    plan_text = "Check internal release marker PLAN-207."
    bridge_text = "Receipt BRIDGE-228 is pending."
    rollout_text = "Validate the rollout owner."

    start_turns!(fn call ->
      case scope(call) do
        "release_plan" -> plan_text
        "provider_delivery" -> {:object, delivery("pending", bridge_text, [root])}
        "impact_and_rollout" -> rollout_text
        "release_synthesis" -> "The delivery and rollout checks are ready for review."
      end
    end)

    assert [parent, bridge, runbook, _] = runs = await_completed!(room, root)
    assert Enum.all?(runs, &(&1.peer_context == false))
    plan_reply = AgentRuns.reply_id(parent.id)
    bridge_reply = AgentRuns.reply_id(bridge.id)
    assert {:ok, %{body: ^plan_text}} = Chat.get_message_view(plan_reply)
    assert {:ok, %{body: ^bridge_text}} = Chat.get_message_view(bridge_reply)

    calls = ScriptedInference.calls()
    assert length(calls) == 4
    independent = Enum.reject(calls, &(scope(&1) == "release_synthesis"))

    assert Enum.sort(Enum.map(independent, &scope/1)) == [
             "impact_and_rollout",
             "provider_delivery",
             "release_plan"
           ]

    assert {:ok, ^rollout_text} =
             Agents.reply_to_handoff(runbook, inference_client: ScriptedInference)

    assert {^calls, [later_check]} = Enum.split(ScriptedInference.calls(), length(calls))
    assert scope(later_check) == "impact_and_rollout"

    for call <- independent ++ [later_check] do
      prompt = input(call)
      assert prompt =~ request
      refute prompt =~ plan_text
      refute prompt =~ bridge_text
      refute prompt =~ plan_reply
      refute prompt =~ bridge_reply
    end

    assert runs_for!(room, root) == runs
    finish_review!(root)
  end

  @tag scenario: "JA08"
  test "Triage cites the exact record returned by its declared read-only Jido Action", %{
    room: room
  } do
    root = compose!(room, "@triage look up the CI result for release JA08.").id
    ci_result = "Package CI fixture RUN-20817 passed compile, lint, and tests."

    assert {:ok, evidence} =
             Chat.send_message(room, ci_result, @eli, thread_id: root, reply_to_id: root)

    assert {:ok, foreign} = Chat.send_message(room, "Separate release report RUN-OTHER.", @eli)
    source_id = evidence.id
    assert {:ok, before_read} = ChatRuntime.get_room_history(room, source_id)
    declared = ReadReleaseEvidence.name()
    plan = "CI run RUN-20817 passed. Check delivery and rollout before approval."

    start_turns!([
      {:tool, declared, %{"message_id" => source_id}},
      plan,
      {:object, delivery("pending", "Confirm the provider receipt.", [root])},
      "Confirm the rollout owner.",
      "Review the open release checks."
    ])

    assert [%{id: plan_id, result: finding}, _, _, _] = await_completed!(room, root)
    assert finding == %{"action" => declared, "source_message_ids" => [source_id]}
    assert {:ok, reply} = Chat.get_message_view(AgentRuns.reply_id(plan_id))
    assert reply.body == plan
    assert reply.metadata["agent_result"] == finding
    assert reply.agent_sources == [%{id: source_id, href: evidence.permalink}]
    assert {:ok, ^before_read} = ChatRuntime.get_room_history(room, source_id)

    assert [first, after_read, bridge, runbook, synthesis] = ScriptedInference.calls()
    assert [%ReqLLM.Tool{name: ^declared}] = Keyword.fetch!(first.options, :tools)
    assert input(first) =~ source_id
    refute input(first) =~ foreign.id
    refute input(first) =~ ci_result

    assert [%{name: ^declared, content: [%{text: result_json}]}] =
             Enum.filter(after_read.messages, &(&1.role == :tool))

    assert %{"id" => ^source_id, "text" => ^ci_result} = Jason.decode!(result_json)

    for call <- [bridge, runbook, synthesis],
        do: assert(Keyword.get(call.options, :tools, []) in [nil, []])

    finish_review!(root)
  end

  @tag scenario: "JA09"
  test "the Jido allowlist blocks an undeclared publish action and makes the failure visible", %{
    room: room
  } do
    root = compose!(room, "@triage check the release action boundary for JA09.").id
    decision_id = ReleaseNotes.decision_anchor(root)
    assert {:ok, decision_before} = ChatRuntime.get_room_history(room, decision_id)
    assert {:ok, delivery_before} = ChatStorage.message_deliveries(root)

    undeclared =
      {:tool, Publication.action(), %{"destination" => "unauthorized", "text" => "JA09"}}

    start_turns!([undeclared, undeclared])

    assert [
             %{
               id: run_id,
               error: "agent_call_limit",
               result: %{"limit" => "model_calls", "model_calls" => 2, "tool_calls" => 0}
             }
           ] =
             await_runs!(room, root, ["failed"])

    assert [first, repair] = ScriptedInference.calls()

    for call <- [first, repair] do
      assert [%ReqLLM.Tool{name: "read_release_evidence"}] = Keyword.fetch!(call.options, :tools)
      refute Enum.any?(call.messages, &(&1.role == :tool))
    end

    assert input(repair) =~ "model requested a tool that is not allowed"
    refusal_id = AgentRuns.reply_id(run_id)

    assert {:ok, %{thread_id: ^root, body: body, metadata: metadata}} =
             Chat.get_message_view(refusal_id)

    assert body =~ "reached the limit for model calls"
    assert metadata["agent_error"] == "agent_call_limit"
    assert metadata["agent_result"]["tool_calls"] == 0

    assert [^decision_id, ^refusal_id] =
             Enum.map(Chat.list_thread_views(room, root, @maya), & &1.id)

    assert {:ok, ^decision_before} = ChatRuntime.get_room_history(room, decision_id)
    assert {:ok, ^delivery_before} = ChatStorage.message_deliveries(root)

    finish_review!(root)
  end

  @tag scenario: "JA10"
  test "the assigned approver prepares an exact publish proposal without a destination write", %{
    room: room
  } do
    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)

    root = compose!(room, "@triage prepare a publish proposal for JA10.").id

    assert {:ok, v1} =
             ReleaseNotes.submit("maya", %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    assert {:ok, v2} =
             ReleaseNotes.submit("eli", %{
               "operation" => "revise",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(v1.id),
               "body" => "Release note v2 includes the updated rollout window."
             })

    destination_id = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination_id)
    assert {:ok, version_view} = Chat.get_message_view(v2.id)
    query = %{"room" => room, "message" => v2.id}
    {maya, maya_server} = init_page(Assembly, %{}, user_id: @maya, query: query)
    {eli, eli_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    assert thread_html(maya, maya_server) =~ "Prepare publish proposal"
    refute thread_html(eli, eli_server) =~ "Prepare publish proposal"

    command =
      Assembly.action(
        :propose_release_publication,
        %{target: ReleaseNotes.message_anchor(v2.id)},
        maya
      ).next_command

    rejected =
      Assembly.command(command.name, Map.put(command.params, :person, "maya"), eli_server)

    assert %{name: :release_action_failed} = rejected.next_action
    assert rejected.broadcasts == []

    assert [%Broadcast{action_name: :message_saved, params: %{message: proposal}}] =
             Assembly.command(command.name, command.params, maya_server).broadcasts

    proposal_id = Publication.proposal_id(v2.id)
    version_id = v2.id
    action = Publication.action()

    assert %{
             id: ^proposal_id,
             sender_id: "agent:triage",
             thread_id: ^root,
             reply_to_id: ^version_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "publish_proposal",
                 "run_id" => ^root,
                 "version_id" => ^version_id,
                 "version" => 2,
                 "action" => ^action,
                 "approver" => "maya",
                 "destination" => %{"id" => ^destination_id, "name" => "#release-log"}
               }
             }
           } = proposal

    assert {:ok, _} = ChatRuntime.get_room_history(room, proposal_id)

    assert {:ok, %{id: ^proposal_id}} =
             ReleaseNotes.submit(
               "maya",
               Map.new(command.params, fn {key, value} -> {to_string(key), value} end)
             )

    assert [^proposal_id] =
             for(%{id: ^proposal_id} <- Chat.list_thread_views(room, root, @eli), do: proposal_id)

    {opened, opened_server} =
      init_page(Assembly, %{}, user_id: @eli, query: %{"room" => room, "message" => proposal_id})

    assert %{thread_root: %{id: ^root}, focused_message_id: ^proposal_id} = opened.state

    card =
      opened
      |> thread_html(opened_server)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(section[aria-label="Publish proposal"]))

    for text <- [
          "#release-log",
          "Release note v2",
          "Maya Reyes",
          action,
          "Awaiting publish approval"
        ] do
      assert LazyHTML.text(card) =~ text
    end

    assert card |> LazyHTML.query("a") |> LazyHTML.attribute("href") |> Enum.uniq() ==
             [version_view.permalink]

    assert card
           |> LazyHTML.query("dd[data-assembly-destination-id]")
           |> LazyHTML.attribute("data-assembly-destination-id")
           |> Enum.uniq() ==
             [destination_id]

    assert {:ok, _review} =
             ReleaseNotes.submit("maya", %{
               "operation" => "review",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(version_id)
             })

    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination_id)
  end

  @tag scenario: "JA11"
  test "an authorized publish approval invokes one Jido Action and links its exact receipt", %{
    room: room
  } do
    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)
    destination = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination)

    root = compose!(room, "@triage demonstrate approved publication for JA11.").id

    assert {:ok, version} =
             ReleaseNotes.submit("maya", %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    version_id = version.id

    review = %{
      "operation" => "review",
      "root" => root,
      "target" => ReleaseNotes.message_anchor(version_id)
    }

    assert {:ok, proposal} =
             ReleaseNotes.submit("eli", %{review | "operation" => "propose_publish"})

    proposal_id = proposal.id
    approval_id = Publication.approval_id(proposal_id)
    target = ReleaseNotes.message_anchor(proposal_id)

    query = %{"room" => room, "message" => proposal_id}
    {before_review, before_review_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    refute thread_html(before_review, before_review_server) =~ "Approve and publish"

    command =
      Assembly.action(:approve_release_publication, %{target: target}, before_review).next_command

    early = Assembly.command(command.name, command.params, before_review_server)

    assert %{name: :release_action_failed, params: %{error: "Mark this version reviewed" <> _}} =
             early.next_action

    assert early.broadcasts == []
    assert {:ok, nil} = ChatRuntime.get_room_history(room, approval_id)

    assert {:ok, _review} = ReleaseNotes.submit("eli", review)
    {maya, maya_server} = init_page(Assembly, %{}, user_id: @maya, query: query)
    {eli, eli_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    refute thread_html(maya, maya_server) =~ "Approve and publish"
    assert thread_html(eli, eli_server) =~ "Approve and publish"

    rejected =
      Assembly.command(command.name, Map.put(command.params, :person, "eli"), maya_server)

    assert %{name: :release_action_failed} = rejected.next_action
    assert rejected.broadcasts == []
    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination)

    handler = {__MODULE__, :publish_action, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido, :action, :start],
               &__MODULE__.track_publication/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert [%Broadcast{action_name: :message_saved, params: %{message: receipt}}] =
             Assembly.command(command.name, command.params, eli_server).broadcasts

    receipt_id = Publication.receipt_id(approval_id)
    post_id = Publication.destination_message_id(approval_id)

    assert %{id: ^receipt_id, thread_id: ^root, reply_to_id: ^approval_id} = receipt
    assert_received :publish_action_invoked

    assert %{
             "assembly_release_note" => %{
               "type" => "publish_receipt",
               "destination_id" => ^destination,
               "destination_message_id" => ^post_id,
               "version_id" => ^version_id
             }
           } =
             receipt.metadata

    assert {:ok, %{sender_id: @eli, thread_id: ^root, reply_to_id: ^proposal_id}} =
             Chat.get_message_view(approval_id)

    assert {:ok, %{id: ^post_id, room_id: ^destination, body: body, permalink: href}} =
             Chat.get_message_view(post_id, @maya)

    assert body == version.body
    assert {:ok, after_publish} = ChatRuntime.list_room_history(destination)
    assert [%{message_id: ^post_id}] = after_publish -- destination_before
    assert {:ok, ^receipt} = Workflow.advance(approval_id)
    refute_received :publish_action_invoked

    {_replay_page, replay_server} = init_page(Assembly, %{}, user_id: @eli, query: query)

    assert [%Broadcast{params: %{message: %{id: ^receipt_id}}}] =
             Assembly.command(command.name, command.params, replay_server).broadcasts

    refute_received :publish_action_invoked
    assert {:ok, ^after_publish} = ChatRuntime.list_room_history(destination)

    assert {:ok, pending} = ChatStorage.ready_release_steps()
    refute approval_id in pending

    {opened, server} =
      init_page(Assembly, %{}, user_id: @maya, query: %{"room" => room, "message" => receipt_id})

    assert %{thread_root: %{id: ^root}, focused_message_id: ^receipt_id} = opened.state

    links =
      opened
      |> thread_html(server)
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(a[href="#{href}"]))

    assert LazyHTML.text(links) =~ "Open published release note"

    {published, _server} =
      init_page(Assembly, %{},
        user_id: @maya,
        query: %{"room" => destination, "message" => post_id}
      )

    assert %{active_room_id: ^destination, focused_message_id: ^post_id} = published.state
  end

  @tag scenario: "JA12"
  test "a revision and a committed revocation both invalidate replayed proposals", %{room: room} do
    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)
    destination = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination)

    root = compose!(room, "@triage check stale publication and revocation for JA12.").id

    assert {:ok, v1} =
             ReleaseNotes.submit("maya", %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    v1_request = %{
      "operation" => "propose_publish",
      "root" => root,
      "target" => ReleaseNotes.message_anchor(v1.id)
    }

    assert {:ok, first} = ReleaseNotes.submit("eli", v1_request)
    first_link = %{"room" => room, "message" => first.id}
    {original, eli_server} = init_page(Assembly, %{}, user_id: @eli, query: first_link)

    stale =
      Assembly.action(
        :approve_release_publication,
        %{target: ReleaseNotes.message_anchor(first.id)},
        original
      ).next_command

    assert {:ok, v2} =
             ReleaseNotes.submit(
               "eli",
               Map.merge(v1_request, %{
                 "operation" => "revise",
                 "body" => "Publish the revised rollout plan after its approval."
               })
             )

    rejected = Assembly.command(stale.name, stale.params, eli_server)
    assert %{name: :release_action_failed, params: %{refresh: true}} = rejected.next_action
    assert rejected.broadcasts == []
    {superseded, superseded_server} = init_page(Assembly, %{}, user_id: @eli, query: first_link)
    assert thread_html(superseded, superseded_server) =~ "A newer version replaced this proposal."
    refute thread_html(superseded, superseded_server) =~ "Revoke proposal"

    v2_request = %{v1_request | "target" => ReleaseNotes.message_anchor(v2.id)}
    assert {:ok, current} = ReleaseNotes.submit("maya", v2_request)
    assert {:ok, _review} = ReleaseNotes.submit("maya", %{v2_request | "operation" => "review"})

    current_id = current.id
    current_link = %{"room" => room, "message" => current_id}
    {maya, maya_server} = init_page(Assembly, %{}, user_id: @maya, query: current_link)
    assert thread_html(maya, maya_server) =~ "Approve and publish"
    assert thread_html(maya, maya_server) =~ "Revoke proposal"

    target = %{target: ReleaseNotes.message_anchor(current_id)}
    approve = Assembly.action(:approve_release_publication, target, maya).next_command
    revoke = Assembly.action(:revoke_release_publication, target, maya).next_command

    wrong_actor =
      Assembly.command(revoke.name, Map.put(revoke.params, :person, "maya"), eli_server)

    assert %{name: :release_action_failed} = wrong_actor.next_action
    assert wrong_actor.broadcasts == []

    assert [%Broadcast{action_name: :message_saved, params: %{message: revocation}}] =
             Assembly.command(revoke.name, revoke.params, maya_server).broadcasts

    revocation_id = Publication.revocation_id(current_id)

    assert %{id: ^revocation_id, sender_id: @maya, thread_id: ^root, reply_to_id: ^current_id} =
             revocation

    assert {:ok, saved_revocation} = ChatRuntime.get_room_history(room, revocation_id)

    assert :ok = Supervisor.terminate_child(@supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(@supervisor, Workflow) end)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, Workflow)

    {reopened, reopened_server} = init_page(Assembly, %{}, user_id: @maya, query: current_link)
    html = thread_html(reopened, reopened_server)
    assert html =~ "Publish proposal revoked."
    refute html =~ "Approve and publish"
    refute html =~ "Revoke proposal"

    for server <- [maya_server, reopened_server] do
      rejected = Assembly.command(approve.name, approve.params, server)
      assert %{name: :release_action_failed, params: %{refresh: true}} = rejected.next_action
      assert rejected.broadcasts == []
    end

    for proposal <- [first, current] do
      approval_id = Publication.approval_id(proposal.id)
      assert {:ok, nil} = ChatRuntime.get_room_history(room, approval_id)
      assert {:ok, nil} = ChatRuntime.get_room_history(room, Publication.receipt_id(approval_id))
      assert {:error, :release_step_unavailable} = Workflow.advance(approval_id)
    end

    assert {:ok, ^saved_revocation} = ChatRuntime.get_room_history(room, revocation_id)
    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination)
  end

  @tag scenario: "RE01"
  test "Bridge resumes after a failed attempt and a worker restart without repeating Triage", %{
    room: room
  } do
    root = compose!(room, "@triage recover the delivery check for RE01.").id
    test = self()

    handler = {__MODULE__, :bridge_retry, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido_assembly, :agent_run, :retry],
               &__MODULE__.track_retry/4,
               test
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_turns!([
      "Check the delivery receipt and identify the rollout owner.",
      fn _call ->
        send(test, {:bridge_attempt, self()})

        receive do
          :fail_attempt -> {:error, :provider_error}
        after
          2_000 -> nil
        end
      end,
      {:object, delivery("confirmed", "Fixture receipt R-01 confirms delivery.", [root])},
      "Maya owns the rollout.",
      "The receipt confirms delivery and Maya owns the rollout."
    ])

    assert_receive {:bridge_attempt, answering}, 2_000

    assert [
             %{id: parent, status: "waiting"},
             %{id: bridge, status: "running", retry_reason: nil},
             %{status: "queued"}
           ] = runs_for!(room, root)

    plan_id = AgentRuns.reply_id(parent)
    assert {:ok, plan_before} = ChatRuntime.get_room_history(room, plan_id)
    assert plan_before.message_id == plan_id

    options = Application.fetch_env!(:jido_assembly, :agent_trigger_options)

    Application.put_env(
      :jido_assembly,
      :agent_trigger_options,
      Keyword.put(options, :enabled, false)
    )

    send(answering, :fail_attempt)

    assert_receive {:agent_retry, %{run_id: ^bridge, reason: :model_call_failed}}, 2_000
    assert {:ok, nil} = ChatRuntime.get_room_history(room, AgentRuns.reply_id(bridge))

    assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
    on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)

    assert {:ok, path} = ChatStorage.path()

    reader =
      start_supervised!(
        {ChatStorage, id: :retry_reader, name: __MODULE__.RetryReader, path: path}
      )

    assert {:ok, restored} = ChatStorage.list_agent_runs(reader, room)

    assert [
             %{id: ^parent, status: "waiting"},
             %{id: ^bridge, status: "queued", retry_reason: "model_call_failed"},
             %{status: "queued"}
           ] = Enum.filter(restored, &(&1.trigger_id == root))

    Application.put_env(:jido_assembly, :agent_trigger_options, options)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)

    assert [
             %{id: ^parent},
             %{id: ^bridge, retry_reason: "model_call_failed", error: nil},
             %{scope: "impact_and_rollout"},
             %{scope: "release_synthesis"}
           ] = await_completed!(room, root)

    assert ~w(release_plan provider_delivery provider_delivery impact_and_rollout release_synthesis) =
             Enum.map(ScriptedInference.calls(), &scope/1)

    assert {:ok, ^plan_before} = ChatRuntime.get_room_history(room, plan_id)

    assert [^plan_id] =
             for(
               %{id: id, metadata: %{"agent_scope" => "release_plan"}} <-
                 Chat.list_thread_views(room, root, @maya),
               do: id
             )

    refute_received {:agent_retry, _metadata}
    finish_review!(root)
  end

  @tag scenario: "RE02"
  test "Triage identifies a required finding when Bridge uses all retries", %{room: room} do
    root = compose!(room, "@triage check the required delivery finding for RE02.").id
    destination = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination)
    assert {:ok, deliveries_before} = ChatStorage.message_deliveries(root)

    start_turns!([
      "Check delivery and rollout.",
      {:error, :provider_error},
      {:error, :provider_error}
    ])

    assert [
             %{id: parent, scope: "release_plan", error: "model_call_failed"},
             %{
               id: bridge,
               retry_reason: "model_call_failed",
               error: "model_call_failed",
               result: nil
             },
             %{scope: "impact_and_rollout", error: "delivery_finding_unavailable", result: nil},
             %{id: stopped, scope: "release_synthesis", error: "required_findings_unavailable"}
           ] = await_runs!(room, root, List.duplicate("failed", 4))

    assert stopped == AgentRuns.handoff_id(parent, "release_synthesis")
    stopped_reply = AgentRuns.reply_id(stopped)
    bridge_reply = AgentRuns.reply_id(bridge)
    plan = AgentRuns.reply_id(parent)
    assert {:ok, bridge_failure} = Chat.get_message_view(bridge_reply, @maya)
    assert bridge_failure.body =~ "after retrying the model call"
    assert {:ok, history_before} = ChatRuntime.list_room_history(room, thread_id: root)

    assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
    on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)
    _ = :sys.get_state(AgentRuns)

    {page, server} =
      init_page(Assembly, %{},
        user_id: @maya,
        query: %{"room" => room, "message" => stopped_reply}
      )

    assert %{thread_root: %{id: ^root}, focused_message_id: ^stopped_reply} = page.state

    assert [
             %{
               sender_id: "agent:triage",
               reply_to_id: ^plan,
               metadata: %{
                 "agent_error" => "required_findings_unavailable",
                 "agent_result" => %{
                   "missing_required_scope" => "provider_delivery",
                   "source_message_ids" => [^bridge_reply]
                 }
               }
             }
           ] = Enum.filter(page.state.thread_messages, &(&1.id == stopped_reply))

    html = thread_html(page, server)
    assert html =~ "Triage stopped because the required Bridge delivery finding is missing."

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("a")
           |> LazyHTML.attribute("href")
           |> Enum.member?(bridge_failure.permalink)

    assert ~w(release_plan provider_delivery provider_delivery) =
             Enum.map(ScriptedInference.calls(), &scope/1)

    assert {:ok, ^history_before} = ChatRuntime.list_room_history(room, thread_id: root)
    assert {:ok, ^deliveries_before} = ChatStorage.message_deliveries(root)
    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination)
    finish_review!(root)
  end

  @tag scenario: "RE03"
  test "Triage continues with verified evidence when the optional rollout check fails", %{
    room: room
  } do
    Application.put_env(:jido_assembly, :agent_trigger_options,
      enabled: false,
      release_delegation: true,
      release_peer_context: false,
      release_rollout_required: false
    )

    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    root = compose!(room, "@triage collect available evidence for RE03.").id
    assert [%{id: parent, rollout_required: false}] = runs_for!(room, root)
    [bridge, rollout] = AgentRuns.finding_run_ids(parent)
    bridge_reply = AgentRuns.reply_id(bridge)
    rollout_reply = AgentRuns.reply_id(rollout)
    synthesis = AgentRuns.handoff_id(parent, "release_synthesis")
    synthesis_reply = AgentRuns.reply_id(synthesis)
    test = self()

    start_turns!(fn call ->
      case scope(call) do
        "release_plan" ->
          "Check delivery and rollout."

        "provider_delivery" ->
          hold_finding(
            test,
            :bridge,
            {:object, delivery("confirmed", "Fixture receipt confirms delivery.", [root])}
          )

        "impact_and_rollout" ->
          {:error, :provider_error}

        "release_synthesis" ->
          "The delivery receipt confirms the release candidate arrived."
      end
    end)

    assert_receive {:finding_started, :bridge, answering}, 3_000
    assert_receive {:signal, %Jido.Signal{id: ^rollout_reply}}, 3_000

    assert [
             %{id: ^parent, status: "waiting", rollout_required: false},
             %{id: ^bridge, status: "running"},
             %{id: ^rollout, status: "failed", error: "inference_failed", rollout_required: false}
           ] = runs_for!(room, root)

    assert {:ok, nil} = ChatRuntime.get_room_history(room, synthesis_reply)

    opts = Application.fetch_env!(:jido_assembly, :agent_trigger_options)

    Application.put_env(
      :jido_assembly,
      :agent_trigger_options,
      Keyword.put(opts, :enabled, false)
    )

    send(answering, :finish_finding)
    await_runs!(room, root, ["waiting", "ready", "failed"])

    assert :ok = Supervisor.terminate_child(@supervisor, AgentRuns)
    on_exit(fn -> Supervisor.restart_child(@supervisor, AgentRuns) end)
    Application.put_env(:jido_assembly, :agent_trigger_options, opts)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, AgentRuns)
    assert_receive {:signal, %Jido.Signal{id: ^synthesis_reply}}, 3_000

    result = %{
      "missing_optional_scopes" => ["impact_and_rollout"],
      "source_message_ids" => [bridge_reply]
    }

    assert [
             %{id: ^parent, rollout_required: false},
             %{id: ^bridge, rollout_required: false},
             %{id: ^rollout},
             %{id: ^synthesis, result: ^result, error: nil}
           ] = await_runs!(room, root, ["completed", "completed", "failed", "completed"])

    assert [call] = Enum.filter(ScriptedInference.calls(), &(scope(&1) == "release_synthesis"))
    assert input(call) =~ "Runbook's optional rollout finding is unavailable."
    assert input(call) =~ bridge_reply
    refute input(call) =~ rollout_reply
    assert length(ScriptedInference.calls()) == 4

    assert {:ok, bridge_view} = Chat.get_message_view(bridge_reply, @eli)

    {page, server} =
      init_page(Assembly, %{},
        user_id: @eli,
        query: %{"room" => room, "message" => synthesis_reply}
      )

    assert %{thread_root: %{id: ^root}, focused_message_id: ^synthesis_reply} = page.state

    assert [
             %{
               id: ^synthesis_reply,
               agent_sources: [%{id: ^bridge_reply, href: href}],
               metadata: %{"agent_result" => ^result}
             }
           ] = Enum.filter(page.state.thread_messages, &(&1.id == synthesis_reply))

    assert href == bridge_view.permalink
    assert thread_html(page, server) =~ "Runbook&#39;s optional rollout finding is unavailable."
    finish_review!(root)
  end

  @tag scenario: "RE04"
  test "the model deadline cancels an unresponsive turn and posts one visible failure", %{
    room: room
  } do
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    root = compose!(room, "@triage apply the model deadline for RE04.").id
    assert [%{id: run}] = runs_for!(room, root)
    reply_id = AgentRuns.reply_id(run)
    test = self()
    timeout = 350

    start_turns!(
      [
        fn _call ->
          send(test, {:unresponsive_model, self(), System.monotonic_time(:millisecond)})

          receive do
            :late_answer -> "This late answer must never reach the thread."
          after
            4_000 -> nil
          end
        end
      ],
      timeout: timeout
    )

    assert_receive {:unresponsive_model, inference_pid, started_at}, 3_000
    monitor = Process.monitor(inference_pid)
    assert_receive {:DOWN, ^monitor, :process, ^inference_pid, _reason}, 1_000
    assert_receive {:signal, %Jido.Signal{id: ^reply_id}}, 1_000
    assert System.monotonic_time(:millisecond) - started_at < timeout + 650

    assert [%{id: ^run, status: "failed", error: "inference_timeout"}] = runs_for!(room, root)
    assert [call] = ScriptedInference.calls()
    assert call.options[:total_timeout] in 1..timeout

    {page, server} =
      init_page(Assembly, %{}, user_id: @maya, query: %{"room" => room, "message" => reply_id})

    assert %{thread_root: %{id: ^root}, focused_message_id: ^reply_id} = page.state
    assert thread_html(page, server) =~ "The model did not respond before the deadline."

    assert {:ok, [%{message_id: _decision}, %{message_id: ^reply_id}]} =
             ChatRuntime.list_room_history(room, thread_id: root)

    finish_review!(root)
  end

  @tag scenario: "RE05"
  test "the Jido model and tool budgets stop repeated work and save the exact limit", %{
    room: room
  } do
    handler = {__MODULE__, :budget_tool, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido, :action, :start],
               &__MODULE__.track_evidence_read/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {limit, limits, model_calls, label} <- [
          {"model_calls", %{model_calls: 1, tool_calls: 2}, 1, "model calls"},
          {"tool_calls", %{model_calls: 2, tool_calls: 1}, 2, "tool calls"}
        ] do
      Application.put_env(:jido_assembly, :agent_trigger_options,
        enabled: false,
        release_delegation: true
      )

      root = compose!(room, "@triage check the #{label} budget for RE05.").id

      assert {:ok, evidence} =
               Chat.send_message(room, "Fixture delivery evidence for RE05.", @eli,
                 thread_id: root,
                 reply_to_id: root
               )

      read = ReadReleaseEvidence.name()

      start_turns!(
        [
          {:tool, read, %{"message_id" => root}},
          {:tool, read, %{"message_id" => evidence.id}},
          {:tool, read, %{"message_id" => root}}
        ],
        call_limits: limits
      )

      assert [%{id: run, error: "agent_call_limit", result: result}] =
               await_runs!(room, root, ["failed"])

      assert %{
               "limit" => ^limit,
               "configured" => 1,
               "model_calls" => ^model_calls,
               "tool_calls" => 1,
               "tool_rounds" => 1
             } = result

      assert length(ScriptedInference.calls()) == model_calls
      assert_received :evidence_read_invoked
      refute_received :evidence_read_invoked

      reply = AgentRuns.reply_id(run)

      assert {:ok, %{metadata: %{"agent_error" => "agent_call_limit", "agent_result" => ^result}}} =
               Chat.get_message_view(reply, @maya)

      {page, server} =
        init_page(Assembly, %{}, user_id: @maya, query: %{"room" => room, "message" => reply})

      assert %{thread_root: %{id: ^root}, focused_message_id: ^reply} = page.state
      assert thread_html(page, server) =~ "reached the limit for #{label}"
      finish_review!(root)
      stop_supervised!(ScriptedInference)
    end
  end

  @tag scenario: "RE06"
  test "the requester cancels a pending publish approval and leaves one terminal state", %{
    room: room
  } do
    root = compose!(room, "@triage prepare a release to cancel in RE06.").id
    destination = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination)

    start_turns!([
      "Check both findings.",
      {:object, delivery("confirmed", "Fixture delivery receipt.", [root])},
      "Eli owns rollout.",
      "Delivery is confirmed and Eli owns rollout."
    ])

    assert [_, _, _, _] = completed = await_completed!(room, root)
    assert {:ok, review} = finish_review!(root)

    assert {:ok, proposal} =
             ReleaseNotes.submit("eli", %{
               "operation" => "propose_publish",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(review.reply_to_id)
             })

    query = %{"room" => room, "message" => proposal.id}
    {maya, maya_server} = init_page(Assembly, %{}, user_id: @maya, query: query)
    {eli, eli_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    assert thread_html(maya, maya_server) =~ "Cancel release run"
    refute thread_html(eli, eli_server) =~ "Cancel release run"
    assert thread_html(eli, eli_server) =~ "Approve and publish"

    cancel =
      Assembly.action(
        :cancel_release_run,
        %{target: ReleaseNotes.message_anchor(root)},
        maya
      ).next_command

    approve =
      Assembly.action(
        :approve_release_publication,
        %{target: ReleaseNotes.message_anchor(proposal.id)},
        eli
      ).next_command

    rejected = Assembly.command(cancel.name, Map.put(cancel.params, :person, "maya"), eli_server)
    assert %{name: :release_action_failed} = rejected.next_action
    assert rejected.broadcasts == []

    handler = {__MODULE__, :cancelled_publication, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido, :action, :start],
               &__MODULE__.track_publication/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert [%Broadcast{action_name: :message_saved, params: %{message: cancellation}}] =
             Assembly.command(cancel.name, cancel.params, maya_server).broadcasts

    cancel_id = ReleaseNotes.cancellation_id(root)
    approval_id = Publication.approval_id(proposal.id)

    assert %{id: ^cancel_id, sender_id: @maya, thread_id: ^root, reply_to_id: ^root} =
             cancellation

    assert [%Broadcast{params: %{message: %{id: ^cancel_id}}}] =
             Assembly.command(cancel.name, cancel.params, maya_server).broadcasts

    assert :ok = Supervisor.terminate_child(@supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(@supervisor, Workflow) end)
    assert {:ok, _pid} = Supervisor.restart_child(@supervisor, Workflow)

    rejected = Assembly.command(approve.name, approve.params, eli_server)
    assert %{name: :release_action_failed, params: %{refresh: true}} = rejected.next_action
    assert rejected.broadcasts == []
    assert {:error, :release_step_unavailable} = Workflow.advance(approval_id)
    refute_received :publish_action_invoked
    assert {:ok, nil} = ChatRuntime.get_room_history(room, approval_id)
    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination)
    assert runs_for!(room, root) == completed
    assert length(ScriptedInference.calls()) == 4

    {reopened, reopened_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    html = thread_html(reopened, reopened_server)
    assert html =~ "Release run cancelled."
    refute html =~ "Approve and publish"
    refute html =~ "Revoke proposal"

    assert [%{id: ^cancel_id}] =
             Enum.filter(
               reopened.state.thread_messages,
               &(&1.metadata["assembly_release_note"]["type"] == "cancelled")
             )

    assert %{status: :cancelled, items: items} =
             Enum.find(reopened.state.release_work.board, &(&1.status == :cancelled))

    assert [%{run_id: ^root, message_id: ^cancel_id}] =
             Enum.filter(items, &(&1.run_id == root))
  end

  @tag scenario: "RE07"
  test "a valid late Bridge result cannot change a cancelled release", %{room: room} do
    root = compose!(room, "@triage check this release before cancellation in RE07.").id
    destination = Seeds.release_log_room_id()
    assert {:ok, destination_before} = ChatRuntime.list_room_history(destination)

    assert {:ok, draft} =
             ReleaseNotes.submit("maya", %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    assert {:ok, proposal} =
             ReleaseNotes.submit("eli", %{
               "operation" => "propose_publish",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(draft.id)
             })

    query = %{"room" => room, "message" => draft.id}
    {eli, eli_server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    {maya, maya_server} = init_page(Assembly, %{}, user_id: @maya, query: query)
    name = ReleaseNotes.message_anchor(draft.id)
    review = Assembly.action(:approve_release_artifact, %{target: name}, eli).next_command
    target = ReleaseNotes.message_anchor(proposal.id)
    approve = Assembly.action(:approve_release_publication, %{target: target}, eli).next_command

    assert [%{message_id: draft_id}] =
             Enum.filter(eli.state.release_work.inbox, &(&1.run_id == root))

    assert draft_id == draft.id
    handler = {__MODULE__, :discarded, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido_assembly, :agent_run, :discarded],
               &__MODULE__.track_discard/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)
    test = self()
    result = delivery("confirmed", "Fixture receipt arrived after cancellation.", [root])

    start_turns!([
      "Check delivery and rollout.",
      fn _request -> hold_finding(test, :bridge, {:object, result}) end
    ])

    assert_receive {:finding_started, :bridge, answering}, 3_000

    assert [
             %{id: parent, status: "waiting"},
             %{id: bridge, status: "running", result: nil},
             %{status: "queued"}
           ] = runs_for!(room, root)

    cancel =
      Assembly.action(
        :cancel_release_run,
        %{target: ReleaseNotes.message_anchor(root)},
        maya
      ).next_command

    assert [%Broadcast{params: %{message: cancellation}}] =
             Assembly.command(cancel.name, cancel.params, maya_server).broadcasts

    cancelled = await_runs!(room, root, ["cancelled", "cancelled", "cancelled"])
    assert {:ok, history} = ChatRuntime.list_room_history(room, thread_id: root)

    send(answering, :finish_finding)

    assert_receive {:agent_discarded,
                    %{run_id: ^bridge, reason: :release_cancelled, outcome: :ok}},
                   3_000

    assert runs_for!(room, root) == cancelled
    assert length(ScriptedInference.calls()) == 2

    assert {:error, :release_evidence_unavailable} =
             ReadReleaseEvidence.run(%{message_id: root}, %{
               assembly_evidence_scope: %{
                 run_id: parent,
                 room_id: room,
                 thread_id: root,
                 request_id: root,
                 source_ids: [root]
               }
             })

    bridge_reply = AgentRuns.reply_id(bridge)

    assert {:error, _reason} =
             Chat.send_message(room, result["summary"], "agent:bridge",
               message_id: bridge_reply,
               thread_id: root,
               reply_to_id: AgentRuns.reply_id(parent),
               role: :assistant,
               metadata: %{
                 agent_run_id: bridge,
                 agent_scope: "provider_delivery",
                 agent_prompt_message_id: root,
                 agent_result: result
               }
             )

    for previous <- [review, approve] do
      assert %{next_action: %{name: :release_action_failed}, broadcasts: []} =
               Assembly.command(previous.name, previous.params, eli_server)
    end

    assert {:ok, ^history} = ChatRuntime.list_room_history(room, thread_id: root)
    assert {:ok, ^destination_before} = ChatRuntime.list_room_history(destination)

    assert {:ok, follow_up} =
             Chat.send_message(room, "@triage does this start another run?", @eli,
               thread_id: root,
               reply_to_id: root
             )

    assert runs_for!(room, follow_up.id) == []
    assert runs_for!(room, root) == cancelled

    {reopened, _server} = init_page(Assembly, %{}, user_id: @eli, query: query)
    refute Enum.any?(reopened.state.release_work.inbox, &(&1.run_id == root))

    assert %{status: :cancelled, items: items} =
             Enum.find(reopened.state.release_work.board, &(&1.status == :cancelled))

    assert [%{message_id: cancel_id, href: href}] = Enum.filter(items, &(&1.run_id == root))
    assert cancel_id == cancellation.id
    assert href == cancellation.permalink
  end

  @tag scenario: "RE09"
  test "publish recovery reconciles an exact destination record or records uncertainty", %{
    room: room
  } do
    Application.put_env(:jido_assembly, :agent_trigger_options, enabled: false)
    destination = Seeds.release_log_room_id()
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)
    on_exit(fn -> Supervisor.restart_child(@supervisor, Workflow) end)

    for outcome <- [:confirmed, :conflict] do
      root = compose!(room, "@triage recover publication #{outcome} in RE09.").id
      assert {:ok, review} = finish_review!(root)
      version_id = review.reply_to_id

      assert {:ok, proposal} =
               ReleaseNotes.submit("eli", %{
                 "operation" => "propose_publish",
                 "root" => root,
                 "target" => ReleaseNotes.message_anchor(version_id)
               })

      assert :ok = Supervisor.terminate_child(@supervisor, Workflow)

      assert {:ok, approval} =
               ReleaseNotes.submit("eli", %{
                 "operation" => "approve_publish",
                 "root" => root,
                 "target" => ReleaseNotes.message_anchor(proposal.id)
               })

      approval_id = approval.id
      post_id = Publication.destination_message_id(approval_id)
      receipt_id = Publication.receipt_id(approval_id)
      uncertain_id = Publication.uncertainty_id(approval_id)

      case outcome do
        :confirmed ->
          assert {:ok, %{"destination_id" => ^destination, "destination_message_id" => ^post_id}} =
                   Jido.Exec.run(PublishReleaseNote, %{approval_id: approval_id})

        :conflict ->
          assert {:ok, _record} =
                   Chat.send_message(
                     destination,
                     "A different note at the expected ID.",
                     "agent:triage",
                     message_id: post_id,
                     role: :assistant,
                     metadata: %{
                       assembly_release_note: %{
                         type: "published",
                         approval_id: approval_id,
                         version_id: version_id
                       }
                     }
                   )
      end

      assert_receive {:signal, %Jido.Signal{id: ^post_id}}, 3_000
      assert {:ok, [^approval_id]} = ChatStorage.ready_release_steps()
      assert {:ok, nil} = ChatRuntime.get_room_history(room, receipt_id)
      assert {:ok, nil} = ChatRuntime.get_room_history(room, uncertain_id)
      assert {:ok, destination_before_recovery} = ChatRuntime.list_room_history(destination)

      id = if outcome == :confirmed, do: receipt_id, else: uncertain_id
      assert {:ok, _pid} = Supervisor.restart_child(@supervisor, Workflow)
      assert_receive {:signal, %Jido.Signal{id: ^id}}, 3_000
      assert {:ok, []} = ChatStorage.ready_release_steps()
      assert {:ok, message} = Chat.get_message_view(id)
      assert %{thread_id: ^root, reply_to_id: ^approval_id} = message
      assert {:ok, %{id: ^id, metadata: metadata}} = Workflow.advance(approval_id)
      assert message.metadata == metadata
      assert {:ok, ^destination_before_recovery} = ChatRuntime.list_room_history(destination)
      refute_receive {:signal, %Jido.Signal{id: ^post_id}}, 250
      refute_received {:signal, %Jido.Signal{id: ^id}}

      query = %{"room" => room, "message" => id}
      {page, server} = init_page(Assembly, %{}, user_id: @eli, query: query)
      assert %{thread_root: %{id: ^root}, focused_message_id: ^id} = page.state
      html = thread_html(page, server)

      case outcome do
        :confirmed ->
          assert %{"type" => "publish_receipt", "destination_message_id" => ^post_id} =
                   metadata["assembly_release_note"]

          assert {:ok, %{permalink: href}} = Chat.get_message_view(post_id, @eli)
          links = html |> LazyHTML.from_document() |> LazyHTML.query(~s(a[href="#{href}"]))
          assert LazyHTML.text(links) =~ "Open published release note"
          assert {:ok, nil} = ChatRuntime.get_room_history(room, uncertain_id)

        :conflict ->
          assert %{"type" => "publish_uncertain", "reason" => "destination_conflict"} =
                   metadata["assembly_release_note"]

          assert html =~ "Assembly could not confirm publication."
          refute html =~ "Approve and publish"
          assert {:ok, nil} = ChatRuntime.get_room_history(room, receipt_id)
      end
    end
  end

  @doc false
  def track_evidence_read(_event, _measurements, %{action: ReadReleaseEvidence}, pid),
    do: send(pid, :evidence_read_invoked)

  def track_evidence_read(_event, _measurements, _metadata, _pid), do: :ok

  @doc false
  def track_retry(_event, _measurements, metadata, pid), do: send(pid, {:agent_retry, metadata})

  @doc false
  def track_discard(_event, _measurements, metadata, pid),
    do: send(pid, {:agent_discarded, metadata})

  @doc false
  def track_publication(_event, _measurements, %{action: PublishReleaseNote}, pid),
    do: send(pid, :publish_action_invoked)

  def track_publication(_event, _measurements, _metadata, _pid), do: :ok

  defp thread_html(page, server) do
    {html, _, _} =
      Renderer.render_dom(
        ThreadPanel.template().(Map.put(page.state, :mobile, false)),
        %Env{},
        server
      )

    html
  end

  defp scope(call) do
    text = input(call)

    cond do
      text =~ "Scope: Identify evidence needs" -> "release_plan"
      text =~ "Scope: Check provider delivery" -> "provider_delivery"
      text =~ "Scope: Check customer impact" -> "impact_and_rollout"
      text =~ "Scope: Combine the provider delivery" -> "release_synthesis"
    end
  end

  defp hold_finding(test, agent, reply) do
    send(test, {:finding_started, agent, self()})

    receive do
      :finish_finding -> reply
    after
      5_000 -> nil
    end
  end

  defp start_turns!(replies, opts \\ []) do
    start_supervised!({ScriptedInference, replies})

    defaults = [release_delegation: true, inference_client: ScriptedInference]
    Application.put_env(:jido_assembly, :agent_trigger_options, Keyword.merge(defaults, opts))
  end

  defp delivery(outcome, summary, source_ids) do
    %{"outcome" => outcome, "summary" => summary, "source_message_ids" => source_ids}
  end

  defp compose!(room, body, user \\ @maya) do
    {page, server} = init_page(Assembly, %{}, user_id: user, query: %{"room" => room})
    command = Assembly.action(:send_message, %{"body" => body}, page).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: message}}] =
             Assembly.command(command.name, command.params, server).broadcasts

    message
  end

  defp input(%{messages: messages}) do
    for %{content: parts} <- messages, %{type: :text, text: text} <- parts do
      text
    end
    |> Enum.join("\n")
  end

  defp runs_for!(room, trigger) do
    assert {:ok, runs} = ChatStorage.list_agent_runs(room)
    Enum.filter(runs, &(&1.trigger_id == trigger))
  end

  defp await_completed!(room, root), do: await_runs!(room, root, List.duplicate("completed", 4))

  defp await_runs!(room, root, statuses, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    runs = runs_for!(room, root)

    if Enum.map(runs, & &1.status) == statuses do
      runs
    else
      assert System.monotonic_time(:millisecond) < deadline, "Handoffs stalled: #{inspect(runs)}"
      Process.sleep(20)
      await_runs!(room, root, statuses, deadline)
    end
  end

  defp finish_review!(root, requester \\ "maya") do
    reviewer = if requester == "maya", do: "eli", else: "maya"

    assert {:ok, draft} =
             ReleaseNotes.submit(requester, %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    assert {:ok, _review} =
             ReleaseNotes.submit(reviewer, %{
               "operation" => "review",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(draft.id)
             })
  end
end
