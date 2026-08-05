defmodule Jido.Assembly.Chat do
  @moduledoc """
  One-workspace chat context for the Assembly Hologram developer demo.

  Assembly keeps the product model intentionally small: one workspace, a few
  demo users, channels, DMs, durable messages, reactions, mentions, search, and
  lightweight thread replies. Canonical records are stored through
  `Jido.Assembly.Messaging`; this module owns the public chat commands and
  delegates read-model maps to `Jido.Assembly.Chat.Projections`.
  """

  alias Jido.Assembly.Chat.{Mentions, Projections}
  alias Jido.Assembly.{Bridges, Inspector, Messaging, Presence, Seeds}
  alias Jido.Messaging.CommandResult

  def workspace_id, do: Seeds.workspace_id()
  def current_user_id, do: Seeds.current_user_id()
  def default_room_id, do: Seeds.default_room_id()
  def reaction_options, do: Seeds.reaction_options()
  def ensure_seeded!, do: Seeds.ensure_seeded!()
  def presence_snapshot, do: Presence.snapshot()
  def connector_snapshot(room_id \\ Seeds.default_room_id()), do: Bridges.snapshot(room_id)

  def demo_users(presence \\ presence_snapshot()) do
    apply_people_presence(Seeds.demo_users(), Map.get(presence, :online_user_ids, []))
  end

  def current_user(user_id \\ Seeds.current_user_id(), presence \\ presence_snapshot()) do
    Projections.person(user_id, presence)
  end

  def snapshot(user_id \\ Seeds.current_user_id(), active_room_id \\ Seeds.default_room_id()) do
    ensure_seeded!()

    presence = presence_snapshot()
    rooms = Projections.room_views(presence)
    {channels, direct_messages} = Projections.split_rooms(rooms)

    active_room =
      Enum.find(rooms, &(&1.id == active_room_id)) ||
        Enum.find(rooms, &(&1.id == Seeds.default_room_id())) || List.first(rooms)

    {messages_by_room, threads_by_room} =
      rooms
      |> Enum.map(fn room ->
        {messages, threads} = Projections.room_message_data(room.id, user_id, presence)
        {room.id, messages, threads}
      end)
      |> Enum.reduce({%{}, %{}}, fn {room_id, messages, threads}, {messages_acc, threads_acc} ->
        {Map.put(messages_acc, room_id, messages), Map.put(threads_acc, room_id, threads)}
      end)

    messages = Map.get(messages_by_room, active_room.id, [])

    %{
      workspace: %{id: Seeds.workspace_id(), name: Seeds.workspace_name()},
      current_user: current_user(user_id, presence),
      demo_users: demo_users(presence),
      presence: presence,
      reaction_options: reaction_options(),
      rooms: rooms,
      channels: channels,
      direct_messages: direct_messages,
      messages_by_room: messages_by_room,
      threads_by_room: threads_by_room,
      active_room: active_room,
      active_room_id: active_room.id,
      active_room_name: active_room.name,
      active_room_kind: active_room.kind,
      active_room_prefix: active_room.prefix,
      active_topic: active_room.topic,
      connector_snapshot: Bridges.snapshot(active_room.id),
      messages: messages,
      member_count_label: active_room.member_count_label,
      inspector:
        Inspector.snapshot(
          active_room,
          messages,
          Map.get(threads_by_room, active_room.id, %{}),
          rooms
        )
    }
  end

  def list_message_views(room_id, user_id \\ Seeds.current_user_id()) when is_binary(room_id) do
    ensure_seeded!()
    Projections.list_message_views(room_id, user_id, presence_snapshot())
  end

  def get_message_view(message_id, user_id \\ Seeds.current_user_id())
      when is_binary(message_id) do
    with {:ok, message} <- Messaging.get_message(message_id) do
      {:ok, Projections.message_view_with_reply_count(message, user_id, presence_snapshot())}
    end
  end

  def list_thread_views(room_id, root_message_id, user_id \\ Seeds.current_user_id()) do
    ensure_seeded!()
    Projections.list_thread_views(room_id, root_message_id, user_id, presence_snapshot())
  end

  def send_message(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ [])
      when is_binary(room_id) do
    case send_message_command(room_id, body, sender_id, opts) do
      {:ok, message, _signals} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message_command(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ [])
      when is_binary(room_id) do
    ensure_seeded!()

    body = body |> to_string() |> String.trim()
    thread_id = opts[:thread_id]
    reply_to_id = opts[:reply_to_id] || thread_id
    role = Keyword.get(opts, :role, :user)
    metadata = Keyword.get(opts, :metadata, %{})

    cond do
      body == "" ->
        {:error, :empty_message}

      true ->
        with {:ok, room} <- Messaging.get_room(room_id),
             :ok <- ensure_thread(room.id, thread_id),
             {:ok, %CommandResult{record: message, signals: signals}} <-
               Messaging.post_message(
                 %{
                   room_id: room.id,
                   sender_id: sender_id,
                   role: role,
                   content: [%{type: "text", text: body}],
                   reply_to_id: reply_to_id,
                   thread_id: thread_id,
                   status: :sent,
                   metadata:
                     %{
                       workspace_id: Seeds.workspace_id(),
                       room_kind: Projections.room_kind(room),
                       source: "jido_assembly"
                     }
                     |> Map.merge(metadata)
                     |> Map.merge(Mentions.metadata(body))
                 },
                 signal_opts(room,
                   payload_kind: "text",
                   target_kind: target_kind(room, thread_id)
                 )
               ) do
          message =
            maybe_route_outbound(room, message, body, role, thread_id, metadata, opts)

          signals = maybe_append_thread_signal(signals, room, message, thread_id)

          {:ok,
           Projections.message_view_with_reply_count(message, sender_id, presence_snapshot()),
           signals}
        end
    end
  end

  defp maybe_route_outbound(room, message, body, role, thread_id, metadata, opts) do
    if route_outbound?(role, thread_id, metadata, opts) do
      room.id
      |> Bridges.route_outbound(body)
      |> then(&Bridges.persist_delivery_result(message, &1))
    else
      message
    end
  end

  defp route_outbound?(_role, _thread_id, _metadata, opts) do
    Keyword.get(opts, :route_outbound, false)
  end

  defp maybe_append_thread_signal(signals, _room, _message, nil), do: signals

  defp maybe_append_thread_signal(signals, room, message, thread_id) do
    data = %{
      root_message_id: thread_id,
      message_id: message.id,
      sender_id: message.sender_id
    }

    case Messaging.dispatch_room_event(
           :thread_reply_added,
           room.id,
           data,
           signal_opts(room,
             message_id: message.id,
             correlation_id: message.id,
             target_kind: "thread"
           )
         ) do
      {:ok, signal} -> signals ++ [signal]
      {:error, _reason} -> signals
    end
  end

  def toggle_reaction(message_id, emoji, user_id \\ Seeds.current_user_id()) do
    case toggle_reaction_command(message_id, emoji, user_id) do
      {:ok, message, _signals} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def toggle_reaction_command(message_id, emoji, user_id \\ Seeds.current_user_id()) do
    ensure_seeded!()

    emoji = to_string(emoji)

    with {:ok, message} <- Messaging.get_message(message_id),
         {:ok, room} <- Messaging.get_room(message.room_id) do
      reactions = message.reactions || %{}
      users = reactions |> Map.get(emoji, []) |> List.wrap() |> Enum.map(&to_string/1)

      command =
        if user_id in users do
          :remove_reaction
        else
          :add_reaction
        end

      with {:ok, %CommandResult{record: updated_message, signals: signals}} <-
             apply(Messaging, command, [
               message_id,
               user_id,
               emoji,
               signal_opts(room,
                 message_id: message_id,
                 correlation_id: message_id,
                 target_kind: target_kind(room, message.thread_id)
               )
             ]) do
        {:ok,
         Projections.message_view_with_reply_count(updated_message, user_id, presence_snapshot()),
         signals}
      end
    end
  end

  def search(query, user_id \\ Seeds.current_user_id()) do
    ensure_seeded!()
    Projections.search(query, user_id, presence_snapshot())
  end

  def touch_presence(user_id, room_id, opts \\ []) do
    ensure_seeded!()
    Presence.touch(user_id, room_id, opts)
  end

  def create_channel(attrs) when is_map(attrs) do
    case create_channel_command(attrs) do
      {:ok, room, messages, _signals} -> {:ok, room, messages}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_channel_command(attrs) when is_map(attrs) do
    ensure_seeded!()

    name =
      attrs
      |> Map.get(:name, Map.get(attrs, "name", ""))
      |> normalize_channel_name()

    topic =
      attrs
      |> Map.get(:topic, Map.get(attrs, "topic", ""))
      |> to_string()
      |> String.trim()

    cond do
      name == "" ->
        {:error, :empty_name}

      true ->
        id = unique_room_id(name)
        position = System.system_time(:millisecond)

        with {:ok, room} <-
               Messaging.create_room(%{
                 id: id,
                 type: :channel,
                 name: name,
                 metadata: %{
                   workspace_id: Seeds.workspace_id(),
                   assembly_kind: "channel",
                   topic: blank_to_default(topic, "Group chat for #{name}."),
                   member_ids: Seeds.demo_user_ids(),
                   position: position
                 }
               }),
             {:ok, %CommandResult{record: message, signals: message_signals}} <-
               Messaging.post_message(
                 %{
                   room_id: room.id,
                   sender_id: Seeds.system_user_id(),
                   role: :system,
                   content: [
                     %{
                       type: "text",
                       text: "Created ##{room.name}. Invite people by sharing this room."
                     }
                   ],
                   status: :sent,
                   metadata: %{
                     workspace_id: Seeds.workspace_id(),
                     source: "jido_assembly",
                     mentions: []
                   }
                 },
                 signal_opts(room, payload_kind: "text", target_kind: "room")
               ),
             {:ok, room_signal} <-
               Messaging.dispatch_room_event(
                 :room_created,
                 room.id,
                 %{
                   room_id: room.id,
                   room_name: room.name,
                   room_kind: "channel",
                   message_ids: [message.id]
                 },
                 signal_opts(room,
                   legacy_event: {:room_created, %{room: room, messages: [message]}},
                   correlation_id: room.id
                 )
               ) do
          presence = presence_snapshot()

          {:ok, Projections.room_view(room, presence),
           [Projections.message_view(message, Seeds.current_user_id(), 0, presence)],
           [room_signal | message_signals]}
        end
    end
  end

  def room_views do
    ensure_seeded!()
    Projections.room_views(presence_snapshot())
  end

  def room_view(room), do: Projections.room_view(room, presence_snapshot())

  def error_to_string(:empty_message), do: "Type a message first."
  def error_to_string(:empty_name), do: "Name the group chat first."
  def error_to_string(:not_found), do: "That room is no longer available."
  def error_to_string(reason), do: "Something went wrong: #{inspect(reason)}"

  defp ensure_thread(_room_id, nil), do: :ok

  defp ensure_thread(room_id, root_message_id) do
    with {:ok, _root_message} <- Messaging.get_message(root_message_id) do
      case Messaging.get_thread(root_message_id) do
        {:ok, _thread} ->
          :ok

        {:error, :not_found} ->
          case Messaging.save_thread(%{
                 id: root_message_id,
                 room_id: room_id,
                 root_message_id: root_message_id,
                 status: :active,
                 metadata: %{workspace_id: Seeds.workspace_id(), source: "jido_assembly"}
               }) do
            {:ok, _thread} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp normalize_channel_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp unique_room_id(name) do
    base = "room:#{name}"

    case Messaging.get_room(base) do
      {:error, :not_found} -> base
      {:ok, _room} -> "#{base}-#{System.unique_integer([:positive])}"
    end
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp signal_opts(room, opts) do
    [
      channel_type: :assembly,
      instance_id: Seeds.workspace_id(),
      external_room_id: room.id,
      chat_type: Projections.room_kind(room)
    ]
    |> Keyword.merge(opts)
  end

  defp target_kind(_room, thread_id) when is_binary(thread_id), do: "thread"

  defp target_kind(room, _thread_id),
    do: if(Projections.room_kind(room) == "dm", do: "dm", else: "room")

  defp apply_people_presence(people, online_user_ids) do
    Enum.map(people, &apply_person_presence(&1, online_user_ids))
  end

  defp apply_person_presence(person, online_user_ids) do
    availability = Map.get(person, :availability, Map.get(person, :presence, "online"))
    online = person.id in online_user_ids

    person
    |> Map.put(:availability, availability)
    |> Map.put(:online, online)
    |> Map.put(:presence, if(online, do: availability, else: "offline"))
  end
end
