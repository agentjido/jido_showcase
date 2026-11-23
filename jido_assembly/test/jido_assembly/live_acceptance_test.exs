defmodule Jido.Assembly.LiveAcceptanceTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{AgentRuns, Agents, Chat, ChatRuntime, ChatStorage, ReleaseNotes, Seeds}
  alias Jido.Assembly.Agents.Actions.PublishReleaseNote
  alias Jido.Assembly.ReleaseNotes.Publication
  alias Jido.Assembly.ScriptedInference

  @moduletag :assembly_live
  @moduletag timeout: 60_000
  @requires_model if(Agents.live_model_configured?(),
                    do: false,
                    else: "Blocked: set ANTHROPIC_API_KEY or JIDO_ASSEMBLY_OLLAMA_MODEL"
                  )

  @tag scenario: "LV01"
  @tag skip: @requires_model
  test "a live model answers at the exact stored request" do
    with_live_agent()
    observe_runs()

    room = Seeds.release_room_id()

    assert {:ok, root} =
             Chat.send_message(
               room,
               "@triage Summarize this test request. The package checks passed. The provider checks are pending.",
               "user:maya"
             )

    request_id = root.id
    deadline = System.monotonic_time(:millisecond) + 45_000

    assert %{id: run_id, status: "completed", thread_id: ^request_id} =
             wait_for_run(room, request_id, deadline)

    reply_id = AgentRuns.reply_id(run_id)
    assert {:ok, record} = ChatRuntime.get_room_history(room, reply_id)

    assert %{
             role: :assistant,
             sender_id: "agent:triage",
             thread_id: ^request_id,
             reply_to_id: ^request_id,
             metadata: %{"agent_run_id" => ^run_id, "agent_prompt_message_id" => ^request_id}
           } = Chat.message_record(record)

    assert [%{id: ^reply_id, body: reply}] = Chat.list_thread_views(room, request_id, "user:maya")
    assert String.trim(reply) != ""

    record_evidence("LV01", %{request_id: request_id, run_id: run_id, reply_id: reply_id})
  end

  @tag scenario: "LV02"
  @tag skip: @requires_model
  @tag timeout: 150_000
  test "live delegation saves both findings and links their exact records from synthesis" do
    with_live_agent(release_delegation: true)
    observe_runs()

    room = Seeds.release_room_id()

    request =
      "@triage Check delivery and rollout for LV02. Fixture receipt TG-LV02-741 confirms the test send. " <>
        "The rollout has an owner and starts with a small cohort."

    root_id = start_release(room, request)
    deadline = System.monotonic_time(:millisecond) + 140_000

    assert %{id: parent, scope: "release_plan", status: "completed"} =
             wait_for_run(room, root_id, deadline)

    assert {:ok, runs} = ChatStorage.list_agent_runs(room)
    related = Enum.filter(runs, &(&1.trigger_id == root_id))
    children = related |> Enum.reject(&(&1.id == parent)) |> Enum.sort_by(& &1.scope)

    assert [
             %{id: rollout, scope: "impact_and_rollout", agent_id: "agent:runbook"},
             %{id: bridge, scope: "provider_delivery", agent_id: "agent:bridge"},
             %{id: synthesis, scope: "release_synthesis", agent_id: "agent:triage"}
           ] = children

    assert Enum.all?(children, &(&1.status == "completed" and &1.parent_run_id == parent))
    bridge_reply = AgentRuns.reply_id(bridge)
    rollout_reply = AgentRuns.reply_id(rollout)
    synthesis_reply = AgentRuns.reply_id(synthesis)
    plan_reply = AgentRuns.reply_id(parent)

    assert {:ok,
            %{
              thread_id: ^root_id,
              reply_to_id: ^plan_reply,
              metadata: %{
                "agent_result" => %{
                  "outcome" => outcome,
                  "summary" => summary,
                  "source_message_ids" => [^root_id]
                }
              }
            }} = Chat.get_message_view(bridge_reply, "user:maya")

    assert outcome in ["confirmed", "pending", "blocked"]
    assert String.trim(summary) != ""

    assert {:ok, %{thread_id: ^root_id, reply_to_id: ^plan_reply, body: finding}} =
             Chat.get_message_view(rollout_reply, "user:maya")

    assert String.trim(finding) != ""

    assert {:ok,
            %{
              thread_id: ^root_id,
              reply_to_id: ^plan_reply,
              metadata: %{
                "agent_result" => %{"source_message_ids" => [^bridge_reply, ^rollout_reply]}
              }
            }} = Chat.get_message_view(synthesis_reply, "user:maya")

    record_evidence("LV02", %{
      request_id: root_id,
      plan_run_id: parent,
      bridge_run_id: bridge,
      runbook_run_id: rollout,
      synthesis_run_id: synthesis,
      delivery_outcome: outcome
    })
  end

  @tag scenario: "LV03"
  @tag skip: @requires_model
  @tag timeout: 150_000
  test "the release with live findings waits for its assignee and reviews one saved version" do
    with_live_agent(release_delegation: true, call_limits: %{model_calls: 4})
    observe_runs()

    room = Seeds.release_room_id()

    root_id =
      start_release(
        room,
        "@triage Review the fixture package for LV03. The package checks passed. Keep the live provider checks pending."
      )

    deadline = System.monotonic_time(:millisecond) + 140_000

    assert %{id: parent, scope: "release_plan", status: "completed"} =
             wait_for_run(room, root_id, deadline)

    synthesis = AgentRuns.handoff_id(parent, "release_synthesis") |> AgentRuns.reply_id()

    assert {:ok, %{thread_id: ^root_id, metadata: %{"agent_parent_run_id" => ^parent}}} =
             Chat.get_message_view(synthesis, "user:maya")

    decision = ReleaseNotes.decision_anchor(root_id)

    assert %{status: :decision, assignee: "maya", target: ^decision, answer: nil, note: nil} =
             release_run(root_id)

    answer = %{
      "operation" => "decide",
      "root" => root_id,
      "target" => decision,
      "choice" => "document"
    }

    assert {:error, _reason} = ReleaseNotes.submit("eli", answer)
    assert %{answer: nil, note: nil} = release_run(root_id)
    assert {:ok, %{id: version, thread_id: ^root_id}} = ReleaseNotes.submit("maya", answer)

    assert %{status: :review, assignee: "eli", answer: %{id: reply}, note: %{id: ^version}} =
             release_run(root_id)

    assert {:ok, %{sender_id: "user:maya", thread_id: ^root_id, reply_to_id: ^decision}} =
             Chat.get_message_view(reply, "user:maya")

    assert {:ok, %{reply_to_id: ^reply}} = Chat.get_message_view(version, "user:eli")

    assert {:ok, %{id: review, thread_id: ^root_id, reply_to_id: ^version, sender_id: "user:eli"}} =
             ReleaseNotes.submit("eli", %{
               "operation" => "review",
               "root" => root_id,
               "target" => ReleaseNotes.message_anchor(version)
             })

    assert %{status: :reviewed, note: %{id: ^version}} = release_run(root_id)

    record_evidence("LV03", %{
      request_id: root_id,
      plan_run_id: parent,
      synthesis_reply_id: synthesis,
      decision_id: decision,
      answer_id: reply,
      version_id: version,
      review_id: review
    })
  end

  @tag scenario: "LV04"
  @tag skip: @requires_model
  @tag timeout: 160_000
  test "a live model recommends publication and only the approver invokes the fixture write" do
    options = [
      release_delegation: true,
      release_publication_recommendation: true,
      inference_client: ScriptedInference
    ]

    with_live_agent(Keyword.put(options, :enabled, false))
    observe_runs()

    handler = {__MODULE__, "LV04", make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido, :action, :start],
               &__MODULE__.publish_started/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)

    room = Seeds.release_room_id()
    destination = Seeds.release_log_room_id()
    assert {:ok, original_history} = ChatRuntime.list_room_history(destination)

    root_id =
      start_release(
        room,
        "@triage Prepare the QA note for internal review. Review criteria: a saved receipt " <>
          "that records delivery, smoke test, rollback, and the rollout owner."
      )

    assert {:ok, %{id: evidence}} =
             Chat.send_message(
               room,
               "QA receipt TG-LV04-741: delivered to the release test room, smoke test passed, " <>
                 "rollback passed, rollout owner Eli. I verified all four fields. " <>
                 "This is the complete record for internal review. No customer impact.",
               "user:eli",
               thread_id: root_id,
               reply_to_id: root_id
             )

    start_supervised!(
      {ScriptedInference,
       [
         "Check the saved QA receipt and rollout owner against the internal review criteria.",
         {:object,
          %{
            "outcome" => "confirmed",
            "summary" => "QA receipt TG-LV04-741 records delivery and a passed smoke test.",
            "source_message_ids" => [evidence]
          }},
         "Eli owns the test rollout. Rollback passed. The test had no customer impact.",
         :live,
         :live
       ]}
    )

    Application.put_env(
      :jido_assembly,
      :agent_trigger_options,
      Keyword.put(options, :enabled, true)
    )

    deadline = System.monotonic_time(:millisecond) + 140_000
    assert %{id: parent, status: "completed"} = wait_for_run(room, root_id, deadline)
    synthesis = AgentRuns.handoff_id(parent, "release_synthesis") |> AgentRuns.reply_id()

    action = Publication.action()

    assert {:ok,
            %{
              thread_id: ^root_id,
              metadata: %{
                "agent_result" => %{
                  "publication_recommendation" => %{
                    "action" => ^action,
                    "destination_id" => ^destination
                  }
                }
              }
            }} = Chat.get_message_view(synthesis, "user:maya")

    assert {:ok, ^original_history} = ChatRuntime.list_room_history(destination)
    refute_received :publish_started

    assert {:ok, %{id: version, body: note}} =
             ReleaseNotes.submit("maya", %{
               "operation" => "decide",
               "root" => root_id,
               "target" => ReleaseNotes.decision_anchor(root_id),
               "choice" => "document"
             })

    target = ReleaseNotes.message_anchor(version)

    assert {:ok, _review} =
             ReleaseNotes.submit("eli", %{
               "operation" => "review",
               "root" => root_id,
               "target" => target
             })

    assert {:ok,
            %{id: proposal, release_publication: %{destination_id: ^destination, action: ^action}}} =
             ReleaseNotes.submit("eli", %{
               "operation" => "propose_publish",
               "root" => root_id,
               "target" => target
             })

    approve = %{
      "operation" => "approve_publish",
      "root" => root_id,
      "target" => ReleaseNotes.message_anchor(proposal)
    }

    assert {:error, _reason} = ReleaseNotes.submit("maya", approve)
    assert {:ok, ^original_history} = ChatRuntime.list_room_history(destination)
    refute_received :publish_started

    approval = Publication.approval_id(proposal)
    post = Publication.destination_message_id(approval)
    receipt = Publication.receipt_id(approval)

    assert {:ok, %{id: ^receipt, reply_to_id: ^approval, thread_id: ^root_id}} =
             ReleaseNotes.submit("eli", approve)

    assert_received :publish_started
    refute_received :publish_started
    assert {:ok, %{id: ^post, body: ^note}} = Chat.get_message_view(post, "user:eli")
    assert {:ok, history} = ChatRuntime.list_room_history(destination)
    assert length(history) == length(original_history) + 1

    record_evidence("LV04", %{
      live_scope: "release_synthesis",
      prior_findings: "scripted",
      request_id: root_id,
      evidence_id: evidence,
      synthesis_reply_id: synthesis,
      version_id: version,
      proposal_id: proposal,
      approval_id: approval,
      receipt_id: receipt,
      published_id: post,
      publication_calls: 1
    })
  end

  @tag scenario: "LV05"
  @tag skip: @requires_model
  test "a live run observes its time and model call limits and records usage" do
    timeout = 20_000
    with_live_agent(timeout: timeout, call_limits: %{model_calls: 1, retries: 0})
    observe_runs()

    handler = {__MODULE__, "LV05", make_ref()}

    assert :ok =
             :telemetry.attach(
               handler,
               [:jido, :ai, :agent, :stop],
               &__MODULE__.agent_stopped/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler) end)
    room = Seeds.release_room_id()

    assert {:ok, %{id: request_id}} =
             Chat.send_message(
               room,
               "@triage In one sentence, state that the fixture package checks passed.",
               "user:maya"
             )

    deadline = System.monotonic_time(:millisecond) + timeout + 5_000

    assert %{id: run, status: "completed", thread_id: ^request_id} =
             wait_for_run(room, request_id, deadline)

    assert_receive {:agent_stopped, %{model_calls: 1, tool_calls: 0, retries: 0} = usage,
                    %{status: :completed, turn_id: turn}},
                   1_000

    elapsed = System.convert_time_unit(usage.duration, :native, :millisecond)
    assert elapsed <= timeout
    assert usage.input_tokens > 0
    assert usage.output_tokens > 0
    refute_received {:agent_stopped, _, _}

    %{model: model} = Agents.snapshot()
    assert String.starts_with?(model, ["anthropic:", "ollama:"])

    IO.puts(
      Jason.encode!(%{
        scenario: "LV05",
        request_id: request_id,
        run_id: run,
        turn_id: turn,
        model: model,
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        model_calls: usage.model_calls,
        elapsed_ms: elapsed,
        outcome: "completed"
      })
    )
  end

  @doc false
  def publish_started(_event, _measurements, %{action: PublishReleaseNote}, pid),
    do: send(pid, :publish_started)

  def publish_started(_event, _measurements, _metadata, _pid), do: :ok

  @doc false
  def agent_stopped(_event, measurements, %{agent_id: "agent:triage:" <> _} = metadata, pid),
    do: send(pid, {:agent_stopped, measurements, metadata})

  def agent_stopped(_event, _measurements, _metadata, _pid), do: :ok

  defp start_release(room, request) do
    assert {:ok, %{id: root_id}, _signals} =
             ReleaseNotes.request_from_chat(room, "user:maya", request)

    on_exit(fn ->
      unless match?(%{status: :reviewed}, release_run(root_id)) do
        assert {:ok, _cancelled} =
                 ReleaseNotes.submit("maya", %{
                   "operation" => "cancel_release",
                   "root" => root_id,
                   "target" => ReleaseNotes.message_anchor(root_id)
                 })
      end
    end)

    root_id
  end

  defp release_run(root_id), do: Enum.find(ReleaseNotes.runs("maya"), &(&1.id == root_id))

  defp record_evidence(scenario, details) do
    evidence = Map.merge(details, %{scenario: scenario, model: Agents.snapshot().model})
    IO.puts(Jason.encode!(evidence))
  end

  defp with_live_agent(options \\ []) do
    previous_mode = Application.fetch_env!(:jido_assembly, :agent_mode)
    previous_options = Application.fetch_env!(:jido_assembly, :agent_trigger_options)

    on_exit(fn ->
      Application.put_env(:jido_assembly, :agent_mode, previous_mode)
      Application.put_env(:jido_assembly, :agent_trigger_options, previous_options)
    end)

    Application.put_env(:jido_assembly, :agent_mode, :live)

    Application.put_env(
      :jido_assembly,
      :agent_trigger_options,
      Keyword.put_new(options, :enabled, true)
    )
  end

  defp observe_runs do
    assert :ok = ChatStorage.subscribe_agent_runs()
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)
  end

  defp wait_for_run(room, request, deadline) do
    assert {:ok, runs} = ChatStorage.list_agent_runs(room)

    case Enum.find(runs, &(&1.trigger_id == request and is_nil(&1.parent_run_id))) do
      %{status: "completed"} = run ->
        run

      %{status: status} when status in ["failed", "cancelled"] ->
        states =
          runs
          |> Enum.filter(&(&1.trigger_id == request))
          |> Enum.map(&Map.take(&1, [:id, :scope, :status, :error]))

        flunk("The live run did not complete. Saved run states: #{inspect(states)}")

      _pending ->
        receive do
          {:agent_run_changed, ^request} ->
            wait_for_run(room, request, deadline)

          {:signal, %Jido.Signal{type: "jido.chat.room.message"}} ->
            wait_for_run(room, request, deadline)
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            flunk("The live run did not reach a terminal state.")
        end
    end
  end
end
