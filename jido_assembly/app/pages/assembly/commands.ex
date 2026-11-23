defmodule Jido.Assembly.Pages.Assembly.Commands do
  @moduledoc """
  Server-side command handlers for the Assembly Hologram page.

  The page module keeps the Hologram callback entry points. This module contains
  the server write path so persistence and broadcast behavior can be reviewed
  without digging through the template.
  """

  import Hologram.Component,
    only: [delete_subscription: 2, put_action: 3, put_broadcast: 4, put_subscription: 2]

  alias Hologram.Server
  alias Jido.Assembly.{Agents, Chat, Pilot, ReleaseNotes, Seeds}
  alias Jido.AssemblyWeb.SignalPresenter

  def viewer_id(server),
    do: server.user_id || Server.get_session(server, :assembly_viewer, Chat.current_user_id())

  def subscribe_direct_rooms(server, snapshot) do
    existing =
      for {{:direct_room, _room_id} = topic, cid} <- server.subscriptions, cid == server.cid do
        topic
      end

    wanted = Enum.map(snapshot.direct_messages, &{:direct_room, &1.id})

    server = Enum.reduce(existing -- wanted, server, &delete_subscription(&2, &1))
    Enum.reduce(wanted -- existing, server, &put_subscription(&2, &1))
  end

  def command(:load_snapshot, params, server) do
    snapshot = Chat.snapshot(viewer_id(server), params.active_room_id)

    server
    |> subscribe_direct_rooms(snapshot)
    |> put_action(:snapshot_loaded, snapshot: snapshot)
  end

  def command(:load_release_work, _params, server) do
    user_id = viewer_id(server)

    put_action(server, :release_work_loaded,
      user_id: user_id,
      work: ReleaseNotes.work_view(user_id)
    )
  end

  def command(:switch_demo_user, params, server) do
    if not Pilot.enabled?() and is_nil(server.user_id) and
         Enum.any?(Seeds.people(), &(&1.id == params.id and is_nil(Map.get(&1, :type)))) do
      server = Server.put_session(server, :assembly_viewer, params.id)
      command(:load_snapshot, params, server)
    else
      put_action(server, :room_access_denied, [])
    end
  end

  def command(:load_room_history, %{room_id: room_id} = params, server) do
    user_id = viewer_id(server)
    before = Map.get(params, :before)

    case Chat.room_history_page(room_id, user_id, before) do
      {:ok, page} ->
        linked =
          case Map.get(params, :focused_message_id) do
            nil -> nil
            id -> Chat.linked_history(room_id, id, user_id)
          end

        payload = %{
          room_id: room_id,
          user_id: user_id,
          requested_before: before,
          page: page,
          linked: linked
        }

        payload =
          if Map.get(params, :refresh_release_work),
            do: Map.put(payload, :release_work, ReleaseNotes.work_view(user_id)),
            else: payload

        put_action(server, :room_history_loaded, payload)

      {:error, _reason} ->
        put_action(server, :room_access_denied, [])
    end
  end

  def command(:touch_presence, params, server) do
    user_id = viewer_id(server)
    room_id = Map.get(params, :room_id, Chat.default_room_id())

    case Chat.touch_presence(user_id, room_id, session_id: presence_session_id(server)) do
      {:ok, presence, signals} ->
        put_workspace_action(server, :presence_changed, %{
          presence: presence,
          signal:
            SignalPresenter.summary(signals, [
              "jido.assembly.presence.changed",
              "jido.assembly.presence.joined"
            ])
        })

      {:error, _reason} ->
        put_action(server, :presence_changed, presence: Chat.presence_snapshot(), signal: nil)
    end
  end

  def command(:persist_message, params, server) do
    user_id = viewer_id(server)

    result =
      case ReleaseNotes.request_from_chat(params.room_id, user_id, params.body) do
        :ordinary_post ->
          Chat.send_message_command(params.room_id, params.body, user_id, route_outbound: true)

        release_request ->
          release_request
      end

    finish_send(server, result, params, :message)
  end

  def command(:persist_reply, params, server) do
    result =
      Chat.send_message_command(params.room_id, params.body, viewer_id(server),
        thread_id: params.root_message_id,
        reply_to_id: params.root_message_id
      )

    finish_send(server, result, params, :reply)
  end

  def command(:persist_reaction, params, server) do
    case Chat.set_reaction_command(
           params.message_id,
           params.emoji,
           viewer_id(server),
           params.active
         ) do
      {:ok, message, [signal | _signals]} ->
        saved = %{
          room_id: message.room_id,
          message: message,
          signal: SignalPresenter.summary(signal)
        }

        if signal.data["changed"] do
          put_room_action(server, :reaction_saved, saved)
        else
          put_action(server, :reaction_saved, saved)
        end

      {:error, reason} ->
        put_action(server, :send_failed, error: Chat.error_to_string(reason))
    end
  end

  def command(:submit_release_action, params, server) do
    operation = Map.get(params, :operation)

    attrs = %{
      "operation" => operation,
      "root" => Map.get(params, :root),
      "target" => Map.get(params, :target),
      "choice" => Map.get(params, :choice),
      "body" => Map.get(params, :body)
    }

    with {:ok, person} <- ReleaseNotes.person_for(viewer_id(server)),
         true <-
           operation in [
             "decide",
             "revise",
             "review",
             "propose_publish",
             "approve_publish",
             "revoke_publish",
             "cancel_release"
           ],
         {:ok, message} <- ReleaseNotes.submit(person, attrs) do
      put_room_action(server, :message_saved, %{room_id: message.room_id, message: message})
    else
      :error ->
        put_action(server, :release_action_failed,
          error: "You do not have access to release reviews."
        )

      false ->
        put_action(server, :release_action_failed, error: "Choose a release action.")

      {:error, reason} ->
        put_action(server, :release_action_failed,
          error: ReleaseNotes.error_to_string(reason),
          refresh: reason == :stale_action
        )
    end
  end

  def command(:run_agent_round, params, server) do
    if not Pilot.enabled?() and Chat.room_visible?(params.room_id, viewer_id(server)) do
      run_agent_round(params, server)
    else
      put_action(server, :room_access_denied, [])
    end
  end

  def command(:prompt_agent_round, params, server) do
    if Pilot.enabled?(),
      do: put_action(server, :room_access_denied, []),
      else: prompt_agent_round(params, server)
  end

  def command(:run_search, params, server) do
    put_action(server, :search_loaded, results: Chat.search(params.query, viewer_id(server)))
  end

  def command(:persist_channel, params, server) do
    case Chat.create_channel_command(%{name: params.name, topic: params.topic}) do
      {:ok, room, messages, signals} ->
        put_workspace_action(server, :room_created, %{
          room: room,
          messages: messages,
          signal: SignalPresenter.summary(signals, "jido.chat.room.message")
        })

      {:error, reason} ->
        put_action(server, :room_create_failed, error: Chat.error_to_string(reason))
    end
  end

  defp run_agent_round(params, server) do
    case Agents.run_round(params.room_id,
           safety_enabled: Map.get(params, :safety_enabled, true),
           inter_agent_enabled: Map.get(params, :inter_agent_enabled, true)
         ) do
      {:ok, result} ->
        put_room_action(server, :agent_round_finished, %{
          room_id: result.room_id,
          messages: result.messages,
          agent_demo: Agents.snapshot(),
          signal: SignalPresenter.summary(result.signals, "jido.chat.room.message")
        })

      {:error, reason} ->
        put_action(server, :agent_round_failed,
          error: Agents.error_to_string(reason),
          agent_demo: Agents.snapshot()
        )
    end
  end

  defp prompt_agent_round(params, server) do
    case Chat.send_message_command(
           params.room_id,
           params.body,
           viewer_id(server),
           metadata: %{agent_prompt: true},
           route_outbound: true
         ) do
      {:ok, prompt_message, prompt_signals} ->
        server =
          put_room_action(server, :message_saved, %{
            room_id: prompt_message.room_id,
            message: prompt_message,
            connector_snapshot: Chat.connector_snapshot(prompt_message.room_id),
            signal: SignalPresenter.summary(prompt_signals, "jido.chat.room.message")
          })

        case Agents.run_round(params.room_id,
               safety_enabled: Map.get(params, :safety_enabled, true),
               inter_agent_enabled: Map.get(params, :inter_agent_enabled, true),
               prompt_message_id: prompt_message.id
             ) do
          {:ok, result} ->
            put_room_action(server, :agent_round_finished, %{
              room_id: result.room_id,
              prompt_message_id: result.prompt_message_id,
              round_index: result.round_index,
              round_limit: result.round_limit,
              messages: result.messages,
              agent_demo: Agents.snapshot(),
              signal: SignalPresenter.summary(result.signals, "jido.chat.room.message")
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

  defp finish_send(server, result, params, composer) do
    ack =
      case Map.fetch(params, :submission_id) do
        {:ok, id} -> %{composer: composer, submission_id: id}
        :error -> %{}
      end

    case result do
      {:ok, message, signals} ->
        saved = %{
          room_id: message.room_id,
          message: message,
          connector_snapshot: Chat.connector_snapshot(message.room_id),
          signal: SignalPresenter.summary(signals, "jido.chat.room.message")
        }

        put_room_action(server, :message_saved, saved, ack)

      {:error, reason} ->
        put_action(server, :send_failed, Map.put(ack, :error, send_error(reason)))
    end
  end

  defp send_error(:request_pending), do: "Finish the open release request first."
  defp send_error(:room_unavailable), do: "The release room is unavailable."
  defp send_error(:message_too_long), do: "Use 2,000 characters or fewer."
  defp send_error(reason), do: Chat.error_to_string(reason)

  defp presence_session_id(server) do
    Enum.join([server.session_id, server.instance_id], ":")
  end

  defp put_workspace_action(server, action, params) do
    server
    |> put_action(action, params)
    |> put_broadcast({:workspace, Chat.workspace_id()}, action, params)
  end

  defp put_room_action(server, action, params, local_params \\ %{}) do
    server = put_action(server, action, Map.merge(params, local_params))

    case Chat.room_topic(params.room_id) do
      nil -> server
      topic -> put_broadcast(server, topic, action, params)
    end
  end
end
