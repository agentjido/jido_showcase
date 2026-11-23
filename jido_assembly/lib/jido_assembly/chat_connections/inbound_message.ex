defmodule Jido.Assembly.ChatConnections.InboundMessage do
  @moduledoc "Admits provider messages and resolves their Assembly thread anchors."

  use Jido.Action, name: "assembly_bridge_inbound", schema: Jido.Joi.map()

  alias Jido.Assembly.{ChatRuntime, ChatStorage}
  alias Jido.Chat.Runtime.Bridge
  alias Jido.Chat.Runtime.Actions.BridgeInbound
  alias Jido.Chat.Runtime.Room.HistoryRecord

  @impl true
  def run(params, context) do
    runtime = context.plugin_inputs[Bridge].runtime

    if runtime.ignore do
      BridgeInbound.run(params, context)
    else
      case ChatStorage.link_for_external(
             ChatStorage,
             runtime.account_id,
             runtime.mapping.external_room,
             context.signal.data["message_id"]
           ) do
        {:ok, %{} = _existing} -> {:ok, context.agent_state, []}
        {:ok, nil} -> import_message(params, context, runtime)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp import_message(params, context, runtime) do
    data = context.signal.data
    room_id = runtime.mapping.room.id
    parent = data["reply_to_id"]

    root =
      if data["thread_id"] not in [data["message_id"], data["room_id"]], do: data["thread_id"]

    runtime = if root, do: runtime, else: %{runtime | thread_local: nil}

    with {:ok, pending} <-
           ChatStorage.pending_bridge_reply(
             runtime.account_id,
             runtime.mapping.external_room,
             data["message_id"]
           ),
         :ok <- verify_pending(pending, room_id, parent, root) do
      cond do
        parent == data["message_id"] ->
          {:error, :invalid_bridge_reply_parent}

        unresolved?(parent, runtime.reply_to_local) or unresolved?(root, runtime.thread_local) ->
          defer(context, runtime, room_id, parent, root)

        true ->
          with {:ok, runtime} <- thread_anchors(room_id, runtime) do
            BridgeInbound.run(params, put_in(context.plugin_inputs[Bridge].runtime, runtime))
          end
      end
    end
  end

  defp verify_pending(nil, _room, _parent, _root), do: :ok
  defp verify_pending(%{room_id: room, parent: parent, root: root}, room, parent, root), do: :ok
  defp verify_pending(_pending, _room, _parent, _root), do: {:error, :bridge_reply_conflict}

  defp unresolved?(external_id, local_id), do: is_binary(external_id) and is_nil(local_id)

  defp defer(context, runtime, room_id, parent, root) do
    pending = %{
      room_id: room_id,
      account_id: runtime.account_id,
      connection: Atom.to_string(context.chat.connection),
      external_room_id: runtime.mapping.external_room,
      external_message_id: context.signal.data["message_id"],
      parent_id: parent,
      root_id: root,
      signal: context.signal
    }

    with :ok <- ChatStorage.defer_bridge_reply(pending), do: {:ok, context.agent_state, []}
  end

  defp thread_anchors(room_id, runtime) do
    with {:ok, root} <- find_anchor(room_id, runtime.thread_local),
         {:ok, parent} <- find_anchor(room_id, runtime.reply_to_local),
         {:ok, root_id, parent_id} <- match_anchors(root, parent) do
      {:ok, %{runtime | thread_local: root_id, reply_to_local: parent_id}}
    end
  end

  defp find_anchor(_room_id, nil), do: {:ok, nil}

  defp find_anchor(room_id, id) do
    case ChatRuntime.get_room_history(room_id, id) do
      {:ok, %HistoryRecord{} = message} -> {:ok, message}
      {:ok, nil} -> {:error, :bridge_anchor_outside_room}
      {:error, _reason} = error -> error
    end
  end

  defp match_anchors(nil, nil), do: {:ok, nil, nil}
  defp match_anchors(%{thread_id: nil, message_id: id}, nil), do: {:ok, id, id}

  defp match_anchors(nil, parent),
    do: {:ok, parent.thread_id || parent.message_id, parent.message_id}

  defp match_anchors(%{thread_id: nil, message_id: id}, %{thread_id: id, message_id: parent}),
    do: {:ok, id, parent}

  defp match_anchors(%{thread_id: nil, message_id: id}, %{thread_id: nil, message_id: id}),
    do: {:ok, id, id}

  defp match_anchors(_root, _parent), do: {:error, :inconsistent_bridge_thread}
end
