defmodule Jido.Assembly.AgentRuns do
  @moduledoc """
  Executes Triage mentions and release handoffs from admitted room messages.

  ChatStorage commits a run with the triggering message. The worker claims
  the run before inference and saves the answer before posting it. After a
  restart, queued runs can start and saved answers can use the same reply ID.
  A failed Bridge model call can queue one durable retry.
  An interrupted inference fails because its result is unknown.
  """

  use GenServer

  alias Jido.Assembly.{Agents, Chat, ChatStorage, Pilot, Seeds}
  alias Jido.Assembly.Chat.{Mentions, Projections}
  alias Jido.Chat.{Actor, Message}

  @agent_id "agent:triage"
  @plan "release_plan"
  @synthesis "release_synthesis"
  @delivery "provider_delivery"
  @rollout "impact_and_rollout"
  @handoff_agents [{"agent:bridge", @delivery}, {"agent:runbook", @rollout}]
  @max_active_runs 3
  @poll_ms 200
  @retry_delay_ms 500

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc false
  def reply_id(run_id), do: run_id <> ":reply"

  @doc false
  def handoff_id(parent_id, scope), do: parent_id <> ":" <> scope

  @doc false
  def reply_parent(%{parent_run_id: nil, trigger_id: trigger}), do: trigger
  def reply_parent(%{parent_run_id: parent}), do: reply_id(parent)

  @doc false
  def trigger(%{signal: %Jido.Signal{data: %{"message" => value}} = signal}) when is_map(value) do
    message = Projections.message_from_fact(signal)

    scope =
      if not Pilot.enabled?() and message.room_id == Seeds.release_room_id(),
        do: release_scope(message)

    with true <- not Pilot.enabled?() or Pilot.agents_enabled?(),
         %Message{role: :user, actor: %Actor{is_self: false}} <- message,
         true <- scope == @plan or eligible_actor?(message),
         true <- @agent_id in Mentions.mentioned_user_ids(Message.fallback_text(message)) do
      hash =
        {message.room_id, message.id, @agent_id}
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.url_encode64(padding: false)

      %{
        id: "run:triage:" <> hash,
        agent_id: @agent_id,
        room_id: message.room_id,
        trigger_id: message.id,
        thread_id: message.thread_id || message.id,
        scope: scope,
        parent_run_id: nil,
        peer_context:
          get_in(message.metadata, ["assembly_release_note", "peer_context"]) != false,
        rollout_required:
          get_in(message.metadata, ["assembly_release_note", "rollout_required"]) != false
      }
    else
      _ineligible -> nil
    end
  end

  def trigger(_record), do: nil

  defp release_scope(%Message{
         role: :user,
         actor: %Actor{kind: :human, id: "user:" <> person},
         thread_id: nil,
         metadata: %{
           "assembly_release_note" => %{
             "type" => "request",
             "person" => person,
             "delegate" => true
           }
         }
       })
       when person in ["maya", "eli"],
       do: @plan

  defp release_scope(_message), do: nil

  @doc false
  def reply(%{signal: %Jido.Signal{data: %{"message" => value}} = signal})
      when is_map(value) do
    case Projections.message_from_fact(signal) do
      %Message{
        id: id,
        role: :assistant,
        actor: %Actor{id: agent_id},
        thread_id: root,
        reply_to_id: reply_to,
        metadata: %{
          "agent_run_id" => run_id,
          "agent_scope" => scope,
          "agent_prompt_message_id" => root
        }
      }
      when is_binary(run_id) and is_binary(root) and is_binary(scope) ->
        if id == reply_id(run_id),
          do: %{id: run_id, scope: scope, agent_id: agent_id, reply_to: reply_to}

      %Message{
        id: id,
        role: :assistant,
        actor: %Actor{id: @agent_id},
        metadata: %{"agent_run_id" => run_id}
      }
      when is_binary(run_id) ->
        if id == reply_id(run_id), do: %{scope: nil}

      _other ->
        nil
    end
  end

  def reply(_record), do: nil

  @doc false
  def handoffs(%{scope: @plan} = run) do
    for {agent_id, scope} <- @handoff_agents do
      %{
        run
        | id: handoff_id(run.id, scope),
          agent_id: agent_id,
          scope: scope,
          parent_run_id: run.id
      }
    end
  end

  @doc false
  def finding_run_ids(parent),
    do: Enum.map(@handoff_agents, fn {_agent, scope} -> handoff_id(parent, scope) end)

  @doc false
  def synthesis(%{parent_run_id: parent} = run) do
    %{run | id: handoff_id(parent, @synthesis), agent_id: @agent_id, scope: @synthesis}
  end

  @doc false
  def blocked_synthesis(%{scope: scope} = run) when scope in [@delivery, @rollout] do
    finding = if scope == @delivery, do: "Bridge delivery", else: "Runbook rollout"

    {synthesis(run),
     %{
       status: "ready",
       error: "required_findings_unavailable",
       reply: "Triage stopped because the required #{finding} finding is missing.",
       result: %{
         "missing_required_scope" => scope,
         "source_message_ids" => [reply_id(run.id)]
       }
     }}
  end

  def blocked_synthesis(_run), do: nil

  defp eligible_actor?(%Message{actor: %Actor{kind: kind}, metadata: metadata} = message)
       when kind in [:human, :unknown] do
    case metadata["jido_chat_origin"] do
      %{"account_id" => account_id} when is_binary(account_id) ->
        true

      _local ->
        match?(%Actor{id: "user:" <> _, kind: :human}, message.actor) and
          not Map.has_key?(metadata, "assembly_release_note") and
          metadata["agent_prompt"] != true
    end
  end

  defp eligible_actor?(_message), do: false

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    {:ok, %{}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    :ok = ChatStorage.interrupt_agent_runs()
    send(self(), :process)
    {:noreply, state}
  end

  @impl true
  def handle_info(:process, tasks) do
    opts = Application.get_env(:jido_assembly, :agent_trigger_options, [])
    infer? = map_size(tasks) < @max_active_runs and Agents.available?(opts)

    {tasks, delay} =
      with true <- Keyword.get(opts, :enabled, true),
           {:ok, %{} = run} <- ChatStorage.next_agent_run(infer?) do
        dispatch(run, opts, tasks)
      else
        _idle -> {tasks, @poll_ms}
      end

    Process.send_after(self(), :process, delay)
    {:noreply, tasks}
  end

  def handle_info({ref, answer}, tasks) when is_reference(ref) and is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {{_task, run}, tasks} = Map.pop(tasks, ref)

    with {:error, :storage_conflict} <- save_answer(run, answer),
         {:ok, %{status: "cancelled"}} <- ChatStorage.get_agent_run(run.id) do
      :telemetry.execute(
        [:jido_assembly, :agent_run, :discarded],
        %{count: 1},
        %{run_id: run.id, reason: :release_cancelled, outcome: elem(answer, 0)}
      )
    end

    {:noreply, tasks}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, tasks) when is_map_key(tasks, ref) do
    {{_task, run}, tasks} = Map.pop(tasks, ref)
    _ = save_answer(run, {:error, :inference_interrupted})
    {:noreply, tasks}
  end

  def handle_info(_message, tasks), do: {:noreply, tasks}

  @impl true
  def terminate(_reason, tasks) do
    Enum.each(tasks, fn {_ref, {task, _run}} -> Task.shutdown(task, :brutal_kill) end)
  end

  defp dispatch(%{status: "queued"} = run, opts, tasks) do
    case ChatStorage.update_agent_run(run.id, "queued", %{status: "running"}) do
      :ok ->
        task = Task.Supervisor.async_nolink(__MODULE__.Tasks, fn -> answer(run, opts) end)
        {Map.put(tasks, task.ref, {task, run}), 0}

      {:error, _reason} ->
        {tasks, @poll_ms}
    end
  end

  defp dispatch(%{status: "ready"} = run, _opts, tasks) do
    delay = if post_reply(run) == :ok, do: 0, else: @poll_ms
    {tasks, delay}
  end

  defp save_answer(run, {:ok, answer}),
    do: ChatStorage.update_agent_run(run.id, "running", ready_changes(answer))

  defp save_answer(%{scope: @delivery, retry_reason: nil} = run, {:error, :model_call_failed}) do
    with :ok <- ChatStorage.retry_agent_run(run.id, "model_call_failed", @retry_delay_ms) do
      :telemetry.execute(
        [:jido_assembly, :agent_run, :retry],
        %{delay_ms: @retry_delay_ms},
        %{run_id: run.id, reason: :model_call_failed}
      )
    end
  end

  defp save_answer(run, {:error, reason}),
    do: ChatStorage.update_agent_run(run.id, "running", failure_changes(run, reason))

  defp post_reply(run) do
    metadata = %{
      source: "jido",
      agent_run_id: run.id,
      agent_prompt_message_id: run.trigger_id
    }

    metadata =
      if run.scope do
        Map.merge(metadata, %{agent_scope: run.scope, agent_parent_run_id: run.parent_run_id})
      else
        metadata
      end

    metadata =
      metadata
      |> put_metadata(:agent_result, run.result)
      |> put_metadata(:agent_error, run.error)

    case Chat.send_message(run.room_id, run.reply, run.agent_id,
           message_id: reply_id(run.id),
           thread_id: run.thread_id,
           reply_to_id: reply_parent(run),
           role: :assistant,
           metadata: metadata
         ) do
      {:ok, _message} when is_binary(run.scope) ->
        :ok

      {:ok, _message} ->
        status = if run.error, do: "failed", else: "completed"
        ChatStorage.update_agent_run(run.id, "ready", %{status: status, error: run.error})

      {:error, _reason} ->
        ChatStorage.update_agent_run(run.id, "ready", %{status: "failed", error: "post_failed"})
    end
  end

  defp put_metadata(metadata, _key, nil), do: metadata
  defp put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp ready_changes(%{body: body, data: data}), do: %{status: "ready", reply: body, result: data}
  defp ready_changes(body) when is_binary(body), do: %{status: "ready", reply: body}

  defp failure_changes(_run, {:agent_call_limit, %{"limit" => limit} = result}) do
    label =
      Map.fetch!(
        %{
          "model_calls" => "model calls",
          "tool_calls" => "tool calls",
          "tool_rounds" => "tool rounds"
        },
        limit
      )

    %{
      status: "ready",
      reply: "This check stopped because it reached the limit for #{label}.",
      error: "agent_call_limit",
      result: result
    }
  end

  defp failure_changes(%{scope: nil}, reason) when reason != :inference_timeout,
    do: %{status: "failed", error: error_code(reason)}

  defp failure_changes(_run, reason) do
    %{
      status: "ready",
      reply: failure_notice(reason),
      error: error_code(reason)
    }
  end

  defp error_code(reason)
       when reason in [
              :invalid_delivery_finding,
              :delivery_finding_unavailable,
              :required_findings_unavailable,
              :model_call_failed,
              :inference_timeout,
              :inference_interrupted,
              :trigger_unavailable
            ],
       do: Atom.to_string(reason)

  defp error_code({:agent_response, :blocked, _reason}), do: "model_response_blocked"
  defp error_code(_reason), do: "inference_failed"

  defp failure_notice(:invalid_delivery_finding),
    do:
      "Bridge returned an invalid delivery finding. Check the required fields and thread sources."

  defp failure_notice(:model_call_failed),
    do: "Bridge could not complete the delivery check after retrying the model call."

  defp failure_notice(:inference_timeout),
    do: "The model did not respond before the deadline. This check stopped."

  defp failure_notice(:delivery_finding_unavailable),
    do: "Runbook stopped because it needs a valid Bridge delivery finding."

  defp failure_notice(:required_findings_unavailable),
    do: "Triage stopped because the release needs both delivery and rollout findings."

  defp failure_notice({:agent_response, :blocked, _reason}),
    do: "This agent stopped because the model response exceeded its permissions or limits."

  defp failure_notice(_reason), do: "This agent could not complete its check."

  defp answer(%{scope: nil} = run, opts),
    do: Agents.reply_to_trigger(run.room_id, run.trigger_id, opts)

  defp answer(run, opts), do: Agents.reply_to_handoff(run, opts)
end
