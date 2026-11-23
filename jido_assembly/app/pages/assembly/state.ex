defmodule Jido.Assembly.Pages.Assembly.State do
  @moduledoc """
  Client-side state reducers for the Assembly Hologram page.

  Hologram actions run in the browser, but they are still ordinary Elixir
  functions. Keeping these transformations here makes the page module mostly a
  coordinator between user events, server commands, and templates.
  """

  import Hologram.Component, only: [put_state: 3]

  alias Jido.Assembly.Chat

  def initial_ui_state do
    [
      draft: "",
      send_pending: nil,
      submission_id: 0,
      error: nil,
      room_form_open: false,
      new_room_name: "",
      new_room_topic: "",
      new_room_pending: false,
      new_room_error: nil,
      search_query: "",
      search_results: [],
      focused_message_id: nil,
      thread_open: false,
      thread_root: nil,
      thread_messages: [],
      reply_draft: "",
      reply_pending: nil,
      reply_error: nil,
      release_error: nil,
      agent_prompt_draft: "",
      agent_round_pending: false,
      agent_error: nil,
      agent_safety_enabled: true,
      agent_inter_agent_enabled: true,
      mobile_panel: "",
      rail_target: "channels",
      workspace_view: "chat"
    ]
  end

  def apply_snapshot(component, snapshot) do
    component
    |> put_release_work(snapshot.current_user.id, Map.get(snapshot, :release_work))
    |> put_state(:workspace, snapshot.workspace)
    |> put_state(:current_user, snapshot.current_user)
    |> put_state(:demo_users, snapshot.demo_users)
    |> put_state(:presence, snapshot.presence)
    |> put_state(:reaction_options, snapshot.reaction_options)
    |> put_state(:rooms, snapshot.rooms)
    |> put_state(:channels, snapshot.channels)
    |> put_state(:direct_messages, snapshot.direct_messages)
    |> put_state(:messages_by_room, snapshot.messages_by_room)
    |> put_state(:threads_by_room, snapshot.threads_by_room)
    |> put_state(:history_cursors, snapshot.history_cursors)
    |> put_state(:active_room, snapshot.active_room)
    |> put_state(:active_room_id, snapshot.active_room_id)
    |> put_state(:active_room_name, snapshot.active_room_name)
    |> put_state(:active_room_kind, snapshot.active_room_kind)
    |> put_state(:active_room_prefix, snapshot.active_room_prefix)
    |> put_state(:active_topic, snapshot.active_topic)
    |> put_state(:connector_snapshot, snapshot.connector_snapshot)
    |> put_state(:member_count_label, snapshot.member_count_label)
    |> put_state(:messages, snapshot.messages)
    |> put_state(:message_count, Enum.count(snapshot.messages))
    |> put_state(:developer_stack, snapshot.inspector.stack)
    |> put_state(:developer_capabilities, snapshot.inspector.capabilities)
    |> put_state(:developer_contract_by_room, snapshot.inspector.contracts_by_room)
    |> put_state(:developer_contract, snapshot.inspector.chat_contract)
    |> put_state(:developer_message_inspector, snapshot.inspector.message_inspector)
    |> put_state(:developer_room_metrics, snapshot.inspector.room_metrics)
    |> put_state(:last_event, snapshot.inspector.last_event)
  end

  def put_release_work(
        %{state: %{current_user: %{id: user_id}, release_work: %{through_sequence: current}}} =
          component,
        user_id,
        work
      ) do
    case work do
      %{through_sequence: sequence} when sequence >= current ->
        put_state(component, :release_work, work)

      _stale_or_unavailable ->
        component
    end
  end

  def put_release_work(component, _user_id, work), do: put_state(component, :release_work, work)

  def select_room(component, room_id) do
    room = Enum.find(component.state.rooms, &(&1.id == room_id)) || component.state.active_room
    messages = Map.get(component.state.messages_by_room, room.id, [])
    rooms = clear_unread(component.state.rooms, room.id)

    component
    |> put_rooms(rooms)
    |> put_state(:rail_target, rail_target_for_room(room))
    |> put_state(:workspace_view, "chat")
    |> put_state(:active_room, room)
    |> put_state(:active_room_id, room.id)
    |> put_state(:active_room_name, room.name)
    |> put_state(:active_room_kind, room.kind)
    |> put_state(:active_room_prefix, room.prefix)
    |> put_state(:active_topic, room.topic)
    |> put_state(:member_count_label, room.member_count_label)
    |> put_state(:messages, messages)
    |> put_state(:message_count, Enum.count(messages))
    |> put_state(:developer_message_inspector, message_inspector(List.last(messages)))
    |> reset_composers()
    |> put_state(:focused_message_id, nil)
    |> put_state(:thread_open, false)
    |> put_state(:thread_root, nil)
    |> put_state(:thread_messages, [])
    |> put_state(:release_error, nil)
    |> put_state(:mobile_panel, "")
    |> put_active_developer_context(
      developer_event("Room selected", "Hologram action", "#{room.prefix}#{room.name}")
    )
  end

  def reset_composers(component) do
    component
    |> put_state(:draft, "")
    |> put_state(:send_pending, nil)
    |> put_state(:error, nil)
    |> reset_reply()
  end

  def reset_reply(component) do
    component
    |> put_state(:reply_draft, "")
    |> put_state(:reply_pending, nil)
    |> put_state(:reply_error, nil)
  end

  def select_first_room(component, []), do: component
  def select_first_room(component, [room | _rooms]), do: select_room(component, room.id)

  def load_history_page(component, page, requested_before) do
    room_id = component.state.active_room_id
    cursors = component.state.history_cursors

    cursors =
      if not Map.has_key?(cursors, room_id) or
           (requested_before && requested_before == Map.get(cursors, room_id)) do
        Map.put(cursors, room_id, page.before)
      else
        cursors
      end

    component
    |> merge_room_history(page.messages, page.threads)
    |> put_state(:history_cursors, cursors)
  end

  def merge_linked_history(component, {:ok, {messages, threads}}),
    do: merge_room_history(component, messages, threads)

  def merge_linked_history(component, _error), do: component

  def merge_room_history(component, messages, threads) do
    state = component.state
    room_id = state.active_room_id

    threads =
      state.threads_by_room
      |> Map.get(room_id, %{})
      |> Map.merge(threads, fn _root_id, current, loaded -> merge_messages(current, loaded) end)

    messages =
      state.messages
      |> merge_messages(messages)
      |> Enum.map(fn message ->
        count = threads |> Map.get(message.id, []) |> length()
        Map.update!(message, :reply_count, &max(&1, count))
      end)

    root_id = state.thread_root && state.thread_root.id
    root = Enum.find(messages, &(&1.id == root_id))

    component
    |> put_state(:messages_by_room, Map.put(state.messages_by_room, room_id, messages))
    |> put_state(:threads_by_room, Map.put(state.threads_by_room, room_id, threads))
    |> put_state(:messages, messages)
    |> put_state(:message_count, length(messages))
    |> put_state(:thread_root, root)
    |> put_state(:thread_messages, Map.get(threads, root_id, []))
  end

  defp merge_messages(current, loaded) do
    existing = Map.new(current, &{&1.id, &1})

    loaded =
      Enum.map(loaded, fn message ->
        case Map.fetch(existing, message.id) do
          {:ok, old} -> preserve_reply_count(old, message)
          :error -> message
        end
      end)

    (loaded ++ current)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&Map.get(&1, :sequence, 0))
  end

  def put_active_developer_context(component, event) do
    room = component.state.active_room
    thread_count = component.state.threads_by_room |> Map.get(room.id, %{}) |> map_size()

    contract =
      Map.get(
        component.state.developer_contract_by_room,
        room.id,
        chat_contract(room)
      )

    component
    |> put_state(
      :developer_room_metrics,
      room_metrics(room, component.state.message_count, thread_count)
    )
    |> put_state(:developer_contract, contract)
    |> put_state(:last_event, event)
  end

  def chat_contract(room) do
    [
      %{
        label: "Room",
        value: "#{room.kind} #{room.id}",
        detail: "Jido.Chat.Runtime.Room.Record"
      },
      %{label: "Payload", value: "text", detail: "Jido.Chat.Post"},
      %{
        label: "Write path",
        value: "Jido.call",
        detail: "SQLite commit plus jido.chat.room.message fact"
      }
    ]
  end

  def developer_event(title, layer, detail) do
    %{
      title: title,
      layer: layer,
      detail: detail
    }
  end

  def message_inspector(nil) do
    inspector = %{
      title: "No message selected",
      provider_payload: %{},
      normalized_message: %{},
      persisted_record: %{},
      delivery: %{}
    }

    put_inspector_text(inspector)
  end

  def message_inspector(message) do
    body = Map.get(message, :body, "")

    inspector = %{
      title: "#{Map.get(message, :source_label, "Local")}: #{String.slice(body, 0, 46)}",
      provider_payload: Map.get(message, :provider_payload, %{}) || %{},
      normalized_message: %{
        id: message.id,
        room_id: message.room_id,
        sender_id: message.sender_id,
        source: Map.get(message, :source, "local"),
        channel: Map.get(message, :channel, "assembly"),
        text: body
      },
      persisted_record: %{
        id: message.id,
        room_id: message.room_id,
        thread_id: message.thread_id,
        reply_to_id: message.reply_to_id,
        status: message.status
      },
      delivery: Map.get(message, :delivery, %{}) || %{}
    }

    put_inspector_text(inspector)
  end

  def room_label(component, room_id) do
    case Enum.find(component.state.rooms, &(&1.id == room_id)) do
      nil -> room_id
      room -> "#{room.prefix}#{room.name}"
    end
  end

  def put_timeline_message(component, room_id, message) do
    messages_for_room = Map.get(component.state.messages_by_room, room_id, [])
    messages_for_room = upsert_message(messages_for_room, message)
    messages_by_room = Map.put(component.state.messages_by_room, room_id, messages_for_room)

    component
    |> put_state(:messages_by_room, messages_by_room)
    |> put_state(:messages, active_messages(component, room_id, messages_for_room))
    |> put_state(:message_count, active_message_count(component, room_id, messages_for_room))
    |> maybe_put_message_inspector(room_id, message)
  end

  def put_thread_reply(component, room_id, message) do
    room_threads = Map.get(component.state.threads_by_room, room_id, %{})
    thread_messages = room_threads |> Map.get(message.thread_id, []) |> upsert_message(message)
    room_threads = Map.put(room_threads, message.thread_id, thread_messages)
    threads_by_room = Map.put(component.state.threads_by_room, room_id, room_threads)

    messages_by_room =
      update_root_reply_count(
        component.state.messages_by_room,
        room_id,
        message.thread_id,
        max(length(thread_messages), Map.get(message, :thread_reply_count, 0))
      )

    component =
      component
      |> put_state(:threads_by_room, threads_by_room)
      |> put_state(:messages_by_room, messages_by_room)
      |> put_state(
        :messages,
        Map.get(messages_by_room, component.state.active_room_id, component.state.messages)
      )

    if component.state.thread_open && component.state.thread_root &&
         component.state.thread_root.id == message.thread_id do
      put_state(component, :thread_messages, thread_messages)
    else
      component
    end
  end

  def update_message_everywhere(component, message) do
    if Map.get(message, :is_reply, false) do
      put_thread_reply(component, message.room_id, message)
    else
      component = put_timeline_message(component, message.room_id, message)

      if component.state.thread_root && component.state.thread_root.id == message.id do
        put_state(component, :thread_root, message)
      else
        component
      end
    end
  end

  def message_present?(component, message) do
    messages =
      if Map.get(message, :is_reply, false) do
        component.state.threads_by_room
        |> Map.get(message.room_id, %{})
        |> Map.get(message.thread_id, [])
      else
        Map.get(component.state.messages_by_room, message.room_id, [])
      end

    Enum.any?(messages, &(&1.id == message.id))
  end

  defp maybe_put_message_inspector(component, room_id, message) do
    if component.state.active_room_id == room_id do
      put_state(component, :developer_message_inspector, message_inspector(message))
    else
      component
    end
  end

  defp put_inspector_text(inspector) do
    inspector
    |> Map.put(
      :provider_payload_text,
      inspect(inspector.provider_payload, pretty: true, limit: 20)
    )
    |> Map.put(
      :normalized_message_text,
      inspect(inspector.normalized_message, pretty: true, limit: 20)
    )
    |> Map.put(
      :persisted_record_text,
      inspect(inspector.persisted_record, pretty: true, limit: 20)
    )
    |> Map.put(:delivery_text, inspect(inspector.delivery, pretty: true, limit: 20))
  end

  def get_thread_messages(_component, nil), do: []

  def get_thread_messages(component, root_id) do
    component.state.threads_by_room
    |> Map.get(component.state.active_room_id, %{})
    |> Map.get(root_id, [])
  end

  def personalize_message(message, user_id) do
    reactions =
      Enum.map(Map.get(message, :reactions, []), fn reaction ->
        user_ids = Map.get(reaction, :user_ids, [])

        reaction
        |> Map.put(:user_ids, user_ids)
        |> Map.put(:reacted, user_id in user_ids)
      end)

    message
    |> Map.put(:own, message.sender_id == user_id)
    |> Map.put(:mentions_current_user, user_id in Map.get(message, :mentioned_user_ids, []))
    |> Map.put(:reactions, reactions)
    |> Map.put(:available_reactions, available_reaction_options(reactions))
  end

  def touch_room(rooms, room_id, active_room_id, own_message, mentions_current_user) do
    Enum.map(rooms, fn room ->
      cond do
        room.id == room_id and room.id == active_room_id ->
          room |> Map.put(:unread, 0) |> Map.put(:mention_unread, 0)

        room.id == room_id and own_message ->
          room

        room.id == room_id ->
          room
          |> Map.put(:unread, room.unread + 1)
          |> Map.put(
            :mention_unread,
            room.mention_unread + if(mentions_current_user, do: 1, else: 0)
          )

        true ->
          room
      end
    end)
  end

  def upsert_room(rooms, new_room) do
    if Enum.any?(rooms, &(&1.id == new_room.id)) do
      Enum.map(rooms, fn room ->
        if room.id == new_room.id, do: new_room, else: room
      end)
    else
      rooms ++ [new_room]
    end
  end

  def put_rooms(component, rooms) do
    component
    |> put_state(:rooms, rooms)
    |> put_state(:channels, Enum.filter(rooms, &(&1.kind == "channel")))
    |> put_state(:direct_messages, Enum.filter(rooms, &(&1.kind == "dm")))
  end

  defp room_metrics(room, message_count, thread_count) do
    [
      %{label: "Room", value: "#{room.prefix}#{room.name}"},
      %{label: "Type", value: room.kind},
      %{label: "Messages", value: Integer.to_string(message_count)},
      %{label: "Threads", value: Integer.to_string(thread_count)},
      %{label: "Durability", value: "SQLite"}
    ]
  end

  defp rail_target_for_room(%{kind: "dm"}), do: "direct_messages"
  defp rail_target_for_room(_room), do: "channels"

  defp upsert_message(messages, new_message) do
    if Enum.any?(messages, &(&1.id == new_message.id)) do
      Enum.map(messages, fn message ->
        if message.id == new_message.id,
          do: preserve_reply_count(message, new_message),
          else: message
      end)
    else
      messages ++ [new_message]
    end
  end

  defp preserve_reply_count(old_message, new_message) do
    Map.put(
      new_message,
      :reply_count,
      max(Map.get(new_message, :reply_count, 0), old_message.reply_count)
    )
  end

  defp update_root_reply_count(messages_by_room, room_id, root_id, reply_count) do
    messages =
      messages_by_room
      |> Map.get(room_id, [])
      |> Enum.map(fn message ->
        if message.id == root_id,
          do: Map.update!(message, :reply_count, &max(&1, reply_count)),
          else: message
      end)

    Map.put(messages_by_room, room_id, messages)
  end

  defp available_reaction_options(reactions) do
    reaction_keys = Enum.map(reactions, & &1.emoji)
    Enum.reject(Chat.reaction_options(), &(&1.key in reaction_keys))
  end

  defp active_messages(component, room_id, messages_for_room) do
    if component.state.active_room_id == room_id do
      messages_for_room
    else
      component.state.messages
    end
  end

  defp active_message_count(component, room_id, messages_for_room) do
    if component.state.active_room_id == room_id do
      Enum.count(messages_for_room)
    else
      component.state.message_count
    end
  end

  defp clear_unread(rooms, room_id) do
    Enum.map(rooms, fn room ->
      if room.id == room_id do
        room |> Map.put(:unread, 0) |> Map.put(:mention_unread, 0)
      else
        room
      end
    end)
  end
end
