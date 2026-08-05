defmodule Jido.Assembly.Pages.Assembly.Commands do
  @moduledoc """
  Server-side command handlers for the Assembly Hologram page.

  The page module keeps the Hologram callback entry points. This module contains
  the server write path so persistence and broadcast behavior can be reviewed
  without digging through the template.
  """

  import Hologram.Component, only: [put_action: 3, put_broadcast: 4]

  alias Jido.Assembly.{Agents, Chat}
  alias Jido.AssemblyWeb.SignalPresenter

  def command(:load_snapshot, params, server) do
    put_action(server, :snapshot_loaded,
      snapshot: Chat.snapshot(params.user_id, params.active_room_id)
    )
  end

  def command(:touch_presence, params, server) do
    user_id = Map.get(params, :user_id, Chat.current_user_id())
    room_id = Map.get(params, :room_id, Chat.default_room_id())

    case Chat.touch_presence(user_id, room_id, session_id: server.session_id) do
      {:ok, presence, signals} ->
        put_workspace_action(server, :presence_changed, %{
          presence: presence,
          signal:
            SignalPresenter.summary(signals, [
              "jido.messaging.participant.presence_changed",
              "jido.messaging.room.participant_joined"
            ])
        })

      {:error, _reason} ->
        put_action(server, :presence_changed, presence: Chat.presence_snapshot(), signal: nil)
    end
  end

  def command(:persist_message, params, server) do
    case Chat.send_message_command(
           params.room_id,
           params.body,
           Map.get(params, :sender_id, Chat.current_user_id()),
           route_outbound: true
         ) do
      {:ok, message, signals} ->
        put_workspace_action(server, :message_saved, %{
          room_id: message.room_id,
          message: message,
          connector_snapshot: Chat.connector_snapshot(message.room_id),
          signal: SignalPresenter.summary(signals, "jido.messaging.room.message_added")
        })

      {:error, reason} ->
        put_action(server, :send_failed, error: Chat.error_to_string(reason))
    end
  end

  def command(:persist_reply, params, server) do
    case Chat.send_message_command(params.room_id, params.body, params.sender_id,
           thread_id: params.root_message_id,
           reply_to_id: params.root_message_id
         ) do
      {:ok, message, signals} ->
        put_workspace_action(server, :message_saved, %{
          room_id: message.room_id,
          message: message,
          connector_snapshot: Chat.connector_snapshot(message.room_id),
          signal: SignalPresenter.summary(signals, "jido.messaging.room.message_added")
        })

      {:error, reason} ->
        put_action(server, :send_failed, error: Chat.error_to_string(reason))
    end
  end

  def command(:persist_reaction, params, server) do
    case Chat.toggle_reaction_command(params.message_id, params.emoji, params.user_id) do
      {:ok, message, [signal | _signals]} ->
        put_workspace_action(server, :reaction_saved, %{
          room_id: message.room_id,
          message: message,
          signal: SignalPresenter.summary(signal)
        })

      {:error, reason} ->
        put_action(server, :send_failed, error: Chat.error_to_string(reason))
    end
  end

  def command(:run_agent_round, params, server) do
    case Agents.run_round(params.room_id,
           safety_enabled: Map.get(params, :safety_enabled, true),
           inter_agent_enabled: Map.get(params, :inter_agent_enabled, true)
         ) do
      {:ok, result} ->
        put_workspace_action(server, :agent_round_finished, %{
          room_id: result.room_id,
          messages: result.messages,
          agent_demo: Agents.snapshot(),
          signal: SignalPresenter.summary(result.signals, "jido.messaging.room.message_added")
        })

      {:error, reason} ->
        put_action(server, :agent_round_failed,
          error: Agents.error_to_string(reason),
          agent_demo: Agents.snapshot()
        )
    end
  end

  def command(:prompt_agent_round, params, server) do
    case Chat.send_message_command(
           params.room_id,
           params.body,
           Map.get(params, :sender_id, Chat.current_user_id()),
           metadata: %{agent_prompt: true},
           route_outbound: true
         ) do
      {:ok, prompt_message, prompt_signals} ->
        server =
          put_workspace_action(server, :message_saved, %{
            room_id: prompt_message.room_id,
            message: prompt_message,
            connector_snapshot: Chat.connector_snapshot(prompt_message.room_id),
            signal: SignalPresenter.summary(prompt_signals, "jido.messaging.room.message_added")
          })

        case Agents.run_round(params.room_id,
               safety_enabled: Map.get(params, :safety_enabled, true),
               inter_agent_enabled: Map.get(params, :inter_agent_enabled, true),
               prompt_message_id: prompt_message.id
             ) do
          {:ok, result} ->
            put_workspace_action(server, :agent_round_finished, %{
              room_id: result.room_id,
              prompt_message_id: result.prompt_message_id,
              round_index: result.round_index,
              round_limit: result.round_limit,
              messages: result.messages,
              agent_demo: Agents.snapshot(),
              signal: SignalPresenter.summary(result.signals, "jido.messaging.room.message_added")
            })

          {:error, reason} ->
            put_action(server, :agent_round_failed,
              error: Agents.error_to_string(reason),
              agent_demo: Agents.snapshot()
            )
        end

      {:error, reason} ->
        put_action(server, :send_failed, error: Chat.error_to_string(reason))
    end
  end

  def command(:run_search, params, server) do
    put_action(server, :search_loaded, results: Chat.search(params.query, params.user_id))
  end

  def command(:persist_channel, params, server) do
    case Chat.create_channel_command(%{name: params.name, topic: params.topic}) do
      {:ok, room, messages, signals} ->
        put_workspace_action(server, :room_created, %{
          room: room,
          messages: messages,
          signal: SignalPresenter.summary(signals, "jido.messaging.room.created")
        })

      {:error, reason} ->
        put_action(server, :room_create_failed, error: Chat.error_to_string(reason))
    end
  end

  defp put_workspace_action(server, action, params) do
    server
    |> put_action(action, params)
    |> put_broadcast({:workspace, Chat.workspace_id()}, action, params)
  end
end
