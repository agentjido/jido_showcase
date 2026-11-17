defmodule Jido.Assembly.Chat.Projections do
  @moduledoc "Assembly read models over durable Jido Chat V3 records."

  alias Jido.Assembly.{ChatRuntime, Seeds}
  alias Jido.Chat.Message
  alias Jido.Chat.Runtime.Room.Reaction

  @avatar_base_url "https://api.dicebear.com/10.x/lorelei/svg"

  def avatar_url(person_id, name \\ nil) do
    seed =
      [person_id, name || person_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")
      |> URI.encode_www_form()

    "#{@avatar_base_url}?seed=#{seed}"
  end

  def room_views(presence \\ %{online_user_ids: []}) do
    case ChatRuntime.list_rooms(limit: 500) do
      {:ok, rooms} ->
        rooms
        |> Enum.filter(&assembly_room?/1)
        |> Enum.sort_by(&room_sort_key/1)
        |> Enum.map(&room_view(&1, presence))

      {:error, _reason} ->
        []
    end
  end

  def room_view(room, presence \\ %{online_user_ids: []}) do
    kind = room_kind(room)
    participant = if kind == "dm", do: dm_participant(room, presence)
    participant_id = participant && participant.id
    availability = if participant, do: participant.availability, else: "active"
    online = not is_nil(participant_id) and online?(presence, participant_id)

    presence_value =
      if participant, do: if(online, do: availability, else: "offline"), else: "active"

    name = if participant, do: participant.name, else: room.name
    member_ids = room_member_ids(room)

    %{
      id: room.id,
      name: name || room.id,
      kind: kind,
      participant_id: participant_id,
      prefix: if(kind == "dm", do: "@", else: "#"),
      topic: metadata_value(room.metadata, :topic, "No topic set."),
      unread: 0,
      mention_unread: 0,
      online: online,
      presence: presence_value,
      availability: availability,
      avatar: if(participant, do: participant.initials, else: "#"),
      avatar_url:
        if(participant,
          do: participant.avatar_url,
          else: avatar_url(room.id, room.name || room.id)
        ),
      tone:
        if(participant, do: participant.tone, else: "bg-[var(--assembly-accent)] text-stone-950"),
      member_count: length(member_ids),
      member_count_label: member_count_label(kind, member_ids, presence_value),
      position: metadata_value(room.metadata, :position, 0)
    }
  end

  def split_rooms(rooms), do: Enum.split_with(rooms, &(&1.kind == "channel"))

  def room_message_data(room_id, user_id, presence \\ %{online_user_ids: []}) do
    case ChatRuntime.list_room_history(room_id, limit: 500) do
      {:ok, history} ->
        messages = Enum.map(history, &message_record/1)

        reply_counts =
          messages |> Enum.reject(&is_nil(&1.thread_id)) |> Enum.frequencies_by(& &1.thread_id)

        timeline =
          messages
          |> Enum.filter(&is_nil(&1.thread_id))
          |> Enum.map(&message_view(&1, user_id, Map.get(reply_counts, &1.id, 0), presence))

        threads =
          messages
          |> Enum.reject(&is_nil(&1.thread_id))
          |> Enum.group_by(& &1.thread_id)
          |> Map.new(fn {thread_id, replies} ->
            {thread_id, Enum.map(replies, &message_view(&1, user_id, 0, presence))}
          end)

        {timeline, threads}

      {:error, _reason} ->
        {[], %{}}
    end
  end

  @doc false
  def message_record(%Jido.Chat.Runtime.Room.HistoryRecord{} = record) do
    message = message_from_fact(record.signal)

    %{
      id: message.id,
      room_id: message.room_id,
      sender_id: message.actor.id,
      role: message.role,
      content: message.content,
      metadata: message.metadata,
      thread_id: message.thread_id,
      reply_to_id: message.reply_to_id,
      inserted_at: record.inserted_at,
      status: :sent,
      reactions: reaction_map(record.room_id, message.id)
    }
  end

  def list_message_views(room_id, user_id, presence \\ %{online_user_ids: []}) do
    {messages, _threads} = room_message_data(room_id, user_id, presence)
    messages
  end

  def list_thread_views(room_id, root_message_id, user_id, presence \\ %{online_user_ids: []}) do
    {_messages, threads} = room_message_data(room_id, user_id, presence)
    Map.get(threads, root_message_id, [])
  end

  def message_view_with_reply_count(message, user_id, presence \\ %{online_user_ids: []}) do
    reply_count =
      if is_binary(message.thread_id) do
        0
      else
        case ChatRuntime.list_room_history(message.room_id, thread_id: message.id, limit: 500) do
          {:ok, replies} -> length(replies)
          {:error, _reason} -> 0
        end
      end

    message_view(message, user_id, reply_count, presence)
  end

  def message_view(message, user_id, reply_count \\ 0, presence \\ %{online_user_ids: []}) do
    sender = person(message.sender_id, presence)
    metadata = message.metadata || %{}
    mentioned_user_ids = metadata_value(metadata, :mentions, [])
    reactions = reaction_views(message.reactions || %{}, user_id)
    source = metadata_value(metadata, :source, "local")
    channel = metadata_value(metadata, :channel, nil)
    author = author_name(sender, metadata)

    %{
      id: message.id,
      room_id: message.room_id,
      sender_id: message.sender_id,
      author: author,
      avatar: sender.initials,
      avatar_url: message_avatar_url(sender, author),
      tone: sender.tone,
      own: message.sender_id == user_id,
      time: format_time(message.inserted_at),
      body: message_text(message),
      status: message.status |> Atom.to_string() |> String.replace("_", " "),
      source: to_string(source || "local"),
      source_label: source_label(source, channel),
      source_detail: source_detail(metadata),
      channel: normalize_optional(channel),
      bridge_id: normalize_optional(metadata_value(metadata, :bridge_id, nil)),
      delivery: delivery_view(message, metadata),
      workflow: workflow_view(metadata),
      provider_payload: metadata_value(metadata, :provider_payload, %{}),
      metadata: metadata,
      thread_id: message.thread_id,
      reply_to_id: message.reply_to_id,
      is_reply: is_binary(message.thread_id),
      reply_count: reply_count,
      mentioned_user_ids: mentioned_user_ids,
      mentions_current_user: user_id in mentioned_user_ids,
      reactions: reactions,
      available_reactions: Seeds.available_reaction_options(reactions)
    }
  end

  def person(person_id, presence \\ %{online_user_ids: []})
  def person(nil, _presence), do: fallback_person("unknown")

  def person(person_id, presence) do
    case Enum.find(people(), &(&1.id == person_id)) do
      nil ->
        fallback_person(person_id)

      profile ->
        availability =
          profile |> Map.get(:availability, Map.get(profile, :presence, :online)) |> to_string()

        online = online?(presence, person_id)
        name = Map.get(profile, :name, person_id)

        %{
          id: person_id,
          name: name,
          initials: Map.get(profile, :initials, initials_for(name)),
          avatar_url: Map.get(profile, :avatar_url, avatar_url(person_id, name)),
          title: Map.get(profile, :title, ""),
          tone: Map.get(profile, :tone, "bg-stone-200 text-stone-950"),
          availability: availability,
          online: online,
          presence: if(online, do: availability, else: "offline")
        }
    end
  end

  def room_kind(room) do
    metadata_value(room.metadata, :assembly_kind, default_room_kind(room.kind))
  end

  def search(query, user_id, presence \\ %{online_user_ids: []}) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      []
    else
      room_views(presence)
      |> Enum.flat_map(fn room ->
        room.id
        |> list_all_message_views(user_id, presence)
        |> Enum.filter(&search_match?(&1, query, room))
        |> Enum.map(&search_result(room, &1))
      end)
      |> Enum.take(20)
    end
  end

  def metadata_value(nil, _key, default), do: default

  def metadata_value(metadata, key, default) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end

  defp people do
    Seeds.demo_users() ++
      Seeds.agent_people() ++
      [%{id: Seeds.system_user_id(), name: "Assembly", initials: "AS", presence: :online}]
  end

  defp default_room_kind(:direct), do: "dm"
  defp default_room_kind(_kind), do: "channel"

  defp source_label("adapter", channel), do: connector_label(channel)
  defp source_label(:adapter, channel), do: connector_label(channel)
  defp source_label("local", channel) when channel in [:telegram, "telegram"], do: "Telegram"
  defp source_label(:local, channel) when channel in [:telegram, "telegram"], do: "Telegram"
  defp source_label("local", channel) when channel in [:discord, "discord"], do: "Discord"
  defp source_label(:local, channel) when channel in [:discord, "discord"], do: "Discord"
  defp source_label("workflow", _channel), do: "Workflow"
  defp source_label(:workflow, _channel), do: "Workflow"
  defp source_label("jido", _channel), do: "Agent"
  defp source_label(:jido, _channel), do: "Agent"
  defp source_label("seed", _channel), do: "Assembly"
  defp source_label(:seed, _channel), do: "Assembly"
  defp source_label("jido_assembly", _channel), do: "Assembly"
  defp source_label(:jido_assembly, _channel), do: "Assembly"
  defp source_label(_source, _channel), do: "Local"

  defp source_detail(metadata) do
    metadata_value(metadata, :workflow_run_id, nil) ||
      metadata_value(metadata, :route_decision, nil) || ""
  end

  defp connector_label(:telegram), do: "Telegram"
  defp connector_label("telegram"), do: "Telegram"
  defp connector_label(:discord), do: "Discord"
  defp connector_label("discord"), do: "Discord"
  defp connector_label(nil), do: "Adapter"
  defp connector_label(channel), do: channel |> to_string() |> String.capitalize()

  defp author_name(sender, metadata) do
    external_name =
      metadata_value(metadata, :display_name, metadata_value(metadata, :username, nil))

    if generated_chat_id?(sender.id) and present?(external_name),
      do: external_name,
      else: sender.name
  end

  defp message_avatar_url(sender, author) do
    if generated_chat_id?(sender.id) and author != sender.name,
      do: avatar_url(sender.id, author),
      else: sender.avatar_url
  end

  defp generated_chat_id?(person_id), do: person_id |> to_string() |> String.starts_with?("jch_")
  defp present?(value), do: value |> to_string() |> String.trim() != ""

  defp delivery_view(message, metadata) do
    %{
      status: message.status |> Atom.to_string() |> String.replace("_", " "),
      route_decision: metadata_value(metadata, :route_decision, "local"),
      attempted: metadata_value(metadata, :attempted, 0),
      delivered: metadata_value(metadata, :delivered, 0),
      failed: metadata_value(metadata, :failed, 0),
      bridge_id: normalize_optional(metadata_value(metadata, :bridge_id, nil)),
      channel: normalize_optional(metadata_value(metadata, :channel, nil)),
      external_room_id:
        normalize_optional(metadata_value(metadata, :delivery_external_room_id, nil)),
      error: normalize_optional(metadata_value(metadata, :delivery_error, nil))
    }
  end

  defp workflow_view(metadata) do
    case metadata_value(metadata, :workflow_event_type, nil) do
      nil ->
        nil

      event_type ->
        %{
          event_type: event_type,
          run_id: metadata_value(metadata, :workflow_run_id, ""),
          severity: metadata_value(metadata, :severity, ""),
          state: metadata_value(metadata, :state, ""),
          actions: metadata_value(metadata, :actions, []),
          external_refs: metadata_value(metadata, :external_refs, [])
        }
    end
  end

  defp normalize_optional(nil), do: ""
  defp normalize_optional(value) when is_binary(value), do: value
  defp normalize_optional(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional(value), do: to_string(value)

  defp list_all_message_views(room_id, user_id, presence) do
    {timeline, threads} = room_message_data(room_id, user_id, presence)
    timeline ++ (threads |> Map.values() |> List.flatten())
  end

  defp message_from_fact(%Jido.Signal{data: %{"message" => %Message{} = message}}), do: message

  defp message_from_fact(%Jido.Signal{data: %{"message" => message}}) when is_map(message),
    do: Message.from_map(message)

  defp reaction_map(room_id, message_id) do
    case ChatRuntime.list_room_reactions(room_id, message_id: message_id) do
      {:ok, reactions} ->
        reactions
        |> Enum.group_by(& &1.reaction, &Reaction.actor/1)
        |> Map.new(fn {reaction, actors} ->
          {reaction, Enum.map(actors, &actor_id/1)}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp actor_id(%Jido.Agent.Address{id: id}), do: id
  defp actor_id(id) when is_binary(id), do: id

  defp reaction_views(reactions, user_id) do
    reactions
    |> Enum.map(fn {emoji, user_ids} ->
      user_ids = List.wrap(user_ids)
      metadata = Seeds.reaction_metadata(emoji)

      %{
        emoji: emoji,
        glyph: metadata.glyph,
        label: metadata.label,
        count: length(user_ids),
        reacted: user_id in user_ids,
        user_ids: user_ids
      }
    end)
    |> Enum.sort_by(& &1.emoji)
  end

  defp search_match?(message, query, room) do
    Enum.any?([message.body, message.author, room.name], fn value ->
      value |> to_string() |> String.downcase() |> String.contains?(query)
    end)
  end

  defp search_result(room, message) do
    %{
      room_id: room.id,
      room_label: "#{room.prefix}#{room.name}",
      message_id: message.id,
      thread_id: message.thread_id,
      author: message.author,
      body: message.body,
      time: message.time
    }
  end

  defp room_sort_key(room) do
    kind_weight = if room_kind(room) == "channel", do: 0, else: 1
    {kind_weight, metadata_value(room.metadata, :position, 0), room.name || ""}
  end

  defp assembly_room?(room),
    do: metadata_value(room.metadata, :workspace_id, nil) == Seeds.workspace_id()

  defp room_member_ids(room) do
    case ChatRuntime.list_room_memberships(room.id, status: :active, limit: 500) do
      {:ok, memberships} -> Enum.map(memberships, &Jido.Chat.Runtime.Room.Membership.member/1)
      {:error, _reason} -> metadata_value(room.metadata, :member_ids, [])
    end
  end

  defp dm_participant(room, presence) do
    room.metadata
    |> metadata_value(:participant_ids, [])
    |> Enum.reject(&(&1 == Seeds.current_user_id()))
    |> List.first()
    |> person(presence)
  end

  defp member_count_label("dm", _member_ids, presence_value), do: presence_value

  defp member_count_label(_kind, member_ids, _presence) do
    count = length(member_ids)
    "#{count} #{if count == 1, do: "member", else: "members"}"
  end

  defp online?(%{online_user_ids: online_user_ids}, participant_id),
    do: participant_id in online_user_ids

  defp online?(_presence, _participant_id), do: false

  defp fallback_person(person_id) do
    %{
      id: person_id,
      name: person_id,
      initials: initials_for(person_id),
      avatar_url: avatar_url(person_id, person_id),
      title: "",
      tone: "bg-stone-200 text-stone-950",
      availability: "offline",
      online: false,
      presence: "offline"
    }
  end

  defp message_text(message) do
    Enum.find_value(message.content, "", fn
      %Jido.Chat.Content{kind: :text, text: text} -> text
      %Jido.Chat.Content{kind: :markdown} = content -> Jido.Chat.Content.fallback_text(content)
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      text when is_binary(text) -> text
      _other -> nil
    end)
  end

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = inserted_at), do: Calendar.strftime(inserted_at, "%H:%M")

  defp initials_for(value) do
    value
    |> to_string()
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> case do
      "" -> "??"
      initials -> initials
    end
  end
end
