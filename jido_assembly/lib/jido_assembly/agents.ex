defmodule Jido.Assembly.Agents do
  @moduledoc """
  On-demand Jido AI agent orchestration for the Assembly developer demo.

  The agents are ordinary Assembly participants. A bounded round starts one
  short-lived graph-first Jido V3 Agent per persona, asks for one chat-sized
  response, then writes the response through `Jido.Assembly.Chat` so durable
  storage, Runtime Signals, Hologram broadcasts, mentions, and reactions all
  use the same path as human messages.
  """

  alias Jido.Assembly.{Chat, ChatRuntime, Seeds}

  @model "anthropic:claude-haiku-4-5"
  @max_agents_per_round 3
  @max_rounds_per_prompt 2
  @max_reply_chars 420
  @recent_message_count 10
  @default_timeout_ms 30_000

  @agent_modules %{
    "agent:triage" => Jido.Assembly.Agents.Triage,
    "agent:bridge" => Jido.Assembly.Agents.Bridge,
    "agent:runbook" => Jido.Assembly.Agents.Runbook
  }

  def all do
    Enum.map(Seeds.agent_people(), fn person ->
      person
      |> Map.take([:id, :name, :handle, :initials, :title, :tone])
      |> Map.put(:module, Map.fetch!(@agent_modules, person.id))
    end)
  end

  def snapshot do
    %{
      agents: Enum.map(all(), &agent_view/1),
      enabled: scripted_mode?() or api_key_present?(),
      model: model_label(),
      safety: %{
        max_agents_per_round: @max_agents_per_round,
        max_rounds_per_prompt: @max_rounds_per_prompt,
        max_reply_chars: @max_reply_chars,
        recent_message_count: @recent_message_count
      },
      missing_api_key: !scripted_mode?() and !api_key_present?()
    }
  end

  def run_round(room_id, opts \\ []) when is_binary(room_id) do
    opts = Keyword.merge(runtime_options(), normalize_opts(opts))
    round_id = "agent-round:#{System.unique_integer([:positive])}"

    max_agents =
      opts |> Keyword.get(:max_agents, @max_agents_per_round) |> clamp(1, @max_agents_per_round)

    agents = all() |> Enum.take(max_agents)

    cond do
      Keyword.get(opts, :safety_enabled, true) != true ->
        {:error, :safety_required}

      !responder?(opts) && !inference_client?(opts) && !api_key_present?() ->
        {:error, :missing_api_key}

      true ->
        with {:ok, room} <- ChatRuntime.get_room(room_id) do
          round_limit =
            opts
            |> Keyword.get(:round_limit, @max_rounds_per_prompt)
            |> clamp(1, @max_rounds_per_prompt)

          prompt_message_id =
            Keyword.get(opts, :prompt_message_id) || latest_human_prompt_id(room.id)

          completed_rounds = prompt_message_id && rounds_for_prompt(room.id, prompt_message_id)

          cond do
            is_nil(prompt_message_id) ->
              {:error, :missing_prompt}

            completed_rounds >= round_limit ->
              {:error, {:round_limit_reached, round_limit}}

            true ->
              transcript = transcript_for(room.id, prompt_message_id)
              inter_agent_enabled = Keyword.get(opts, :inter_agent_enabled, true)

              opts =
                opts
                |> Keyword.put(:prompt_message_id, prompt_message_id)
                |> Keyword.put(:round_index, completed_rounds + 1)
                |> Keyword.put(:round_limit, round_limit)

              agents
              |> Enum.reduce_while({:ok, [], [], transcript}, fn agent,
                                                                 {:ok, messages, signals,
                                                                  transcript} ->
                case agent_turn(agent, room, transcript, round_id, opts) do
                  {:ok, message, turn_signals, next_line} ->
                    next_transcript =
                      if inter_agent_enabled do
                        transcript ++ [next_line]
                      else
                        transcript
                      end

                    {:cont,
                     {:ok, messages ++ [message], signals ++ turn_signals, next_transcript}}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end
              end)
              |> case do
                {:ok, messages, signals, _transcript} ->
                  {:ok,
                   %{
                     room_id: room.id,
                     prompt_message_id: prompt_message_id,
                     round_id: round_id,
                     round_index: completed_rounds + 1,
                     round_limit: round_limit,
                     agents: Enum.map(agents, &agent_view/1),
                     messages: messages,
                     signals: signals
                   }}

                {:error, reason} ->
                  {:error, reason}
              end
          end
        end
    end
  end

  @doc "Returns the explicit local Agent mode options."
  def runtime_options do
    if scripted_mode?(), do: [responder: &scripted_reply/4], else: []
  end

  def error_to_string(:missing_api_key), do: "Add ANTHROPIC_API_KEY before running AI agents."
  def error_to_string(:missing_prompt), do: "Ask a question before running the agents."
  def error_to_string(:safety_required), do: "Turn the safety cap back on before running agents."
  def error_to_string(:empty_agent_reply), do: "The agent returned an empty reply."

  def error_to_string({:round_limit_reached, _limit}),
    do: "Round limit reached for this question. Ask a new question to restart."

  def error_to_string({:agent_failed, name, reason}), do: "#{name} failed: #{inspect(reason)}"
  def error_to_string(reason), do: "Agent round failed: #{inspect(reason)}"

  defp agent_turn(agent, room, transcript, round_id, opts) do
    prompt = prompt_for(agent, room, transcript, opts)

    with {:ok, reply} <- generate_reply(agent, room, transcript, prompt, opts),
         {:ok, reply} <- normalize_reply(reply, agent.name),
         {:ok, message, signals} <-
           Chat.send_message_command(room.id, reply, agent.id,
             role: :assistant,
             metadata: %{
               source: "jido",
               agent_id: agent.id,
               agent_name: agent.name,
               agent_round_id: round_id,
               agent_round_index: Keyword.fetch!(opts, :round_index),
               agent_round_limit: Keyword.fetch!(opts, :round_limit),
               agent_prompt_message_id: Keyword.fetch!(opts, :prompt_message_id),
               model: model_label()
             }
           ) do
      {:ok, message, signals,
       %{author: agent.name, body: reply, sender_id: agent.id, agent: true}}
    else
      {:error, reason} -> {:error, {:agent_failed, agent.name, reason}}
    end
  end

  defp generate_reply(agent, room, transcript, prompt, opts) do
    case Keyword.get(opts, :responder) do
      nil ->
        ask_agent(agent, prompt, opts)

      responder when is_function(responder, 4) ->
        responder.(agent, room, transcript, opts)

      responder when is_function(responder, 3) ->
        responder.(agent, room, transcript)
    end
  end

  defp ask_agent(agent, prompt, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    agent_id = "#{agent.id}:#{System.unique_integer([:positive])}"

    signal =
      agent.module.request_signal!(%{
        input: prompt,
        model: @model,
        options: %{temperature: 0.35, max_tokens: 140},
        limits: %{model_calls: 2, retries: 1, elapsed_ms: timeout}
      })

    with {:ok, pid} <- Jido.start_agent(Jido.Assembly.Jido, agent.module, id: agent_id),
         :ok <- Jido.AgentServer.await_ready(pid) do
      try do
        call_opts = [timeout: timeout, context: inference_context(opts)]

        pid
        |> Jido.AgentServer.call(signal, call_opts)
        |> agent_reply()
      after
        _ = Jido.stop_agent(Jido.Assembly.Jido, pid)
      end
    end
  end

  defp agent_reply(
         {:ok,
          %Jido.AgentServer.TurnResult{
            status: :committed,
            reply: %{data: %{status: :completed, output: output}}
          }}
       )
       when is_binary(output),
       do: {:ok, output}

  defp agent_reply(
         {:ok,
          %Jido.AgentServer.TurnResult{
            reply: %{data: %{status: status} = data}
          }}
       )
       when status in [:blocked, :failed],
       do: {:error, {:agent_response, status, Map.get(data, :reason)}}

  defp agent_reply({:ok, %Jido.AgentServer.TurnResult{status: status, error: error}}),
    do: {:error, {:agent_turn, status, error}}

  defp agent_reply({:error, reason}), do: {:error, reason}

  defp inference_context(opts) do
    case Keyword.get(opts, :inference_client) do
      client when is_atom(client) -> %{jido_ai_inference_client: client}
      _other -> %{}
    end
  end

  defp prompt_for(agent, room, transcript, opts) do
    inter_agent_enabled = Keyword.get(opts, :inter_agent_enabled, true)
    round_index = Keyword.fetch!(opts, :round_index)
    round_limit = Keyword.fetch!(opts, :round_limit)

    visible_transcript =
      if inter_agent_enabled do
        transcript
      else
        Enum.reject(transcript, &Map.get(&1, :agent, false))
      end

    transcript_text =
      visible_transcript
      |> Enum.take(-@recent_message_count)
      |> Enum.map_join("\n", fn line -> "#{line.author}: #{line.body}" end)
      |> blank_to_default("No prior messages in this room.")

    peer_instruction =
      if inter_agent_enabled do
        "React to prior agent turns when useful."
      else
        "Ignore agent turns. Answer the human prompt only."
      end

    """
    Room: #{room.name}
    Agent: #{agent.name} / #{agent.title}
    Round: #{round_index}/#{round_limit}
    Transcript:
    #{transcript_text}

    #{peer_instruction}
    Reply as #{agent.name}. Max 2 short sentences. No preamble.
    """
  end

  defp transcript_for(room_id, prompt_message_id) do
    views =
      room_id
      |> Chat.list_message_views()
      |> messages_from(prompt_message_id)

    views
    |> Enum.take(-@recent_message_count)
    |> Enum.map(fn message ->
      %{
        author: message.author,
        body: compact_text(message.body),
        sender_id: message.sender_id,
        agent: String.starts_with?(message.sender_id, "agent:")
      }
    end)
  end

  defp messages_from(messages, nil), do: messages

  defp messages_from(messages, prompt_message_id) do
    messages
    |> Enum.drop_while(&(&1.id != prompt_message_id))
    |> case do
      [] -> messages
      prompted_messages -> prompted_messages
    end
  end

  defp latest_human_prompt_id(room_id) do
    room_id
    |> timeline_messages()
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      if human_user_message?(message), do: message.id
    end)
  end

  defp rounds_for_prompt(room_id, prompt_message_id) do
    room_id
    |> timeline_messages()
    |> Enum.filter(&(metadata_value(&1.metadata, :agent_prompt_message_id) == prompt_message_id))
    |> Enum.map(&metadata_value(&1.metadata, :agent_round_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.count()
  end

  defp timeline_messages(room_id) do
    case ChatRuntime.list_room_history(room_id, limit: 500) do
      {:ok, history} -> Enum.map(history, &Chat.message_record/1)
      {:error, _reason} -> []
    end
  end

  defp human_user_message?(message) do
    message.role == :user and not String.starts_with?(message.sender_id, "agent:")
  end

  defp normalize_reply({:ok, reply}, agent_name), do: normalize_reply(reply, agent_name)
  defp normalize_reply({:error, reason}, _agent_name), do: {:error, reason}

  defp normalize_reply(reply, agent_name) do
    reply =
      reply
      |> extract_text()
      |> compact_text()
      |> strip_speaker_prefix(agent_name)
      |> truncate_text(@max_reply_chars)

    if reply == "" do
      {:error, :empty_agent_reply}
    else
      {:ok, reply}
    end
  end

  defp extract_text(value) when is_binary(value), do: value
  defp extract_text(%{text: text}) when is_binary(text), do: text
  defp extract_text(%{"text" => text}) when is_binary(text), do: text

  defp extract_text(value), do: inspect(value)

  defp compact_text(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp strip_speaker_prefix(text, agent_name) do
    Regex.replace(~r/^#{Regex.escape(agent_name)}\s*:\s*/i, text, "")
  end

  defp truncate_text(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      text |> String.slice(0, max_chars) |> String.trim_trailing() |> Kernel.<>("...")
    end
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp agent_view(agent) do
    %{
      id: agent.id,
      name: agent.name,
      handle: agent.handle,
      initials: agent.initials,
      title: agent.title,
      tone: agent.tone
    }
  end

  defp model_label do
    if scripted_mode?(), do: "scripted:jido-assembly-demo", else: @model
  end

  defp scripted_reply(agent, room, transcript, _opts) do
    {:ok,
     "#{agent.name} checked #{room.name} with #{Enum.count(transcript)} visible messages. The scripted V3 path is ready for the next bounded step."}
  end

  defp scripted_mode?, do: Application.get_env(:jido_assembly, :agent_mode, :live) == :scripted

  defp api_key_present? do
    present?(System.get_env("ANTHROPIC_API_KEY"))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp responder?(opts), do: Keyword.has_key?(opts, :responder)
  defp inference_client?(opts), do: Keyword.has_key?(opts, :inference_client)

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, _min, max), do: max
end
