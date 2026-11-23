defmodule Jido.Assembly.Chat do
  @moduledoc """
  One-workspace chat context for the Assembly V3 showcase.

  Jido Chat Runtime owns durable Rooms, memberships, messages, reactions, and
  turn evidence. Assembly owns display profiles, search, and UI projections.
  """

  alias Jido.Assembly.Chat.{Mentions, Projections}
  alias Jido.Assembly.{Bridges, ChatRuntime, Inspector, Pilot, Presence, ReleaseNotes, Seeds}
  alias Jido.Chat.{Actor, Content, FileSource, Media, Post}
  alias Jido.Chat.Runtime.Room.Reaction

  alias Jido.Chat.Runtime.Signal.Room.{AddReaction, Join, RemoveReaction}
  alias Jido.Chat.Runtime.Signal.Room.Post, as: PostSignal

  @room_definition "assembly.room.v1"
  @max_attachment_bytes 1_048_576

  def workspace_id, do: Seeds.workspace_id()
  def current_user_id, do: Seeds.current_user_id()
  def default_room_id, do: Seeds.default_room_id()
  def reaction_options, do: Seeds.reaction_options()
  def ensure_seeded!, do: Seeds.ensure_seeded!()
  def presence_snapshot, do: Presence.snapshot()
  def connector_snapshot(room_id \\ Seeds.default_room_id()), do: Bridges.snapshot(room_id)

  def demo_users(presence \\ presence_snapshot()) do
    if Pilot.enabled?() do
      []
    else
      apply_people_presence(Seeds.demo_users(), Map.get(presence, :online_user_ids, []))
    end
  end

  def current_user(user_id \\ Seeds.current_user_id(), presence \\ presence_snapshot()) do
    Projections.person(user_id, presence)
  end

  def snapshot(user_id \\ Seeds.current_user_id(), active_room_id \\ Seeds.default_room_id()) do
    ensure_seeded!()

    presence = presence_snapshot()
    rooms = Projections.room_views(presence, user_id)
    {channels, direct_messages} = Projections.split_rooms(rooms)

    active_room =
      Enum.find(rooms, &(&1.id == active_room_id)) ||
        Enum.find(rooms, &(&1.id == Seeds.default_room_id())) || List.first(rooms)

    if active_room do
      {messages_by_room, threads_by_room, history_cursors} =
        project_room_data(rooms, user_id, presence)

      messages = Map.get(messages_by_room, active_room.id, [])

      %{
        workspace: %{id: Seeds.workspace_id(), name: Seeds.workspace_name()},
        current_user: current_user(user_id, presence),
        release_work: ReleaseNotes.work_view(user_id),
        demo_users: demo_users(presence),
        presence: presence,
        reaction_options: reaction_options(),
        rooms: rooms,
        channels: channels,
        direct_messages: direct_messages,
        messages_by_room: messages_by_room,
        threads_by_room: threads_by_room,
        history_cursors: history_cursors,
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
    else
      empty_snapshot(user_id, presence)
    end
  end

  def list_message_views(room_id, user_id \\ Seeds.current_user_id()) when is_binary(room_id) do
    ensure_seeded!()
    Projections.list_message_views(room_id, user_id, presence_snapshot())
  end

  def get_message_view(message_id, user_id \\ Seeds.current_user_id())
      when is_binary(message_id) do
    with {:ok, record} <- find_history(message_id) do
      {:ok,
       Projections.message_view_with_reply_count(
         message_record(record),
         user_id,
         presence_snapshot()
       )}
    end
  end

  def list_thread_views(room_id, root_message_id, user_id \\ Seeds.current_user_id()) do
    ensure_seeded!()
    Projections.list_thread_views(room_id, root_message_id, user_id, presence_snapshot())
  end

  @doc "Returns the timeline and threads for one room."
  def room_conversation(room_id, user_id) do
    ensure_seeded!()
    Projections.room_message_data(room_id, user_id, presence_snapshot())
  end

  def room_history_page(room_id, user_id, before \\ nil) do
    if room_visible?(room_id, user_id) do
      Projections.history_page(room_id, user_id, presence_snapshot(), before)
    else
      {:error, :not_found}
    end
  end

  def linked_history(room_id, message_id, user_id) do
    if room_visible?(room_id, user_id) do
      Projections.linked_history(room_id, message_id, user_id, presence_snapshot())
    else
      {:error, :not_found}
    end
  end

  def room_visible?(room_id, user_id) do
    case ChatRuntime.get_room(room_id) do
      {:ok, room} -> Projections.room_visible?(room, user_id)
      _ -> false
    end
  end

  def room_topic(room_id) do
    case ChatRuntime.get_room(room_id) do
      {:ok, %{kind: :direct}} -> {:direct_room, room_id}
      {:ok, _room} -> {:workspace, workspace_id()}
      _ -> nil
    end
  end

  def send_message(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ []) do
    case send_message_command(room_id, body, sender_id, opts) do
      {:ok, message, _signals} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message_command(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ [])
      when is_binary(room_id) do
    body = body |> to_string() |> String.trim()

    if body == "" do
      {:error, :empty_message}
    else
      send_post(room_id, body, [Content.text(body)], sender_id, opts)
    end
  end

  @doc "Stores a small attachment and optional caption as one durable chat post."
  def send_attachment(room_id, attachment, sender_id \\ Seeds.current_user_id(), opts \\ [])

  def send_attachment(
        room_id,
        %{filename: filename, media_type: media_type, bytes: bytes},
        sender_id,
        opts
      )
      when is_binary(room_id) and is_binary(filename) and is_binary(media_type) and
             is_binary(bytes) and byte_size(bytes) in 1..@max_attachment_bytes do
    filename = String.trim(filename)

    if valid_attachment_name?(filename) and Regex.match?(~r/^[\w.+-]+\/[\w.+-]+$/u, media_type) do
      caption = opts |> Keyword.get(:caption, "") |> to_string() |> String.trim()
      source = FileSource.base64(Base.encode64(bytes), filename, media_type: media_type)

      media =
        Media.new(%{
          kind: :file,
          source: source,
          name: filename,
          media_type: media_type,
          metadata: %{"size_bytes" => byte_size(bytes)}
        })

      content = if caption == "", do: [], else: [Content.text(caption)]

      case send_post(room_id, caption, content ++ [Content.media(media)], sender_id, opts) do
        {:ok, message, _signals} -> {:ok, message}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_attachment}
    end
  end

  def send_attachment(_room_id, _attachment, _sender_id, _opts), do: {:error, :invalid_attachment}

  defp valid_attachment_name?(filename) do
    filename not in ["", ".", ".."] and byte_size(filename) <= 255 and
      not String.match?(filename, ~r/[[:cntrl:]\/\\]/u)
  end

  defp send_post(room_id, body, content, sender_id, opts) do
    ensure_seeded!()

    with {:ok, _room} <- ChatRuntime.get_room(room_id),
         :ok <- ensure_thread(room_id, opts[:thread_id], opts[:reply_to_id]),
         {:ok, result} <- post(room_id, body, content, sender_id, opts),
         {:ok, record} <- ChatRuntime.get_room_history(room_id, reply_message_id(result)) do
      {:ok,
       Projections.message_view_with_reply_count(
         message_record(record),
         sender_id,
         presence_snapshot()
       ), committed_signals(result)}
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

    with {:ok, record} <- find_history(message_id),
         {:ok, current} <-
           ChatRuntime.get_room_reaction(record.room_id, message_id, emoji, user_id) do
      persist_reaction(record, emoji, user_id, not match?(%Reaction{status: :active}, current))
    end
  end

  def set_reaction_command(message_id, emoji, user_id, active?) when is_boolean(active?) do
    ensure_seeded!()

    with {:ok, record} <- find_history(message_id) do
      persist_reaction(record, emoji, user_id, active?)
    end
  end

  def set_reaction_command(_message_id, _emoji, _user_id, _active?),
    do: {:error, :invalid_reaction}

  defp persist_reaction(record, emoji, user_id, active?) do
    module = if active?, do: AddReaction, else: RemoveReaction

    with {:ok, request} <- module.new(%{"message_id" => record.message_id, "reaction" => emoji}),
         {:ok, result} <- room_call(record.room_id, request, user_id) do
      {:ok,
       Projections.message_view_with_reply_count(
         message_record(record),
         user_id,
         presence_snapshot()
       ), committed_signals(result)}
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
    name = attrs |> Map.get(:name, Map.get(attrs, "name", "")) |> normalize_channel_name()
    topic = attrs |> Map.get(:topic, Map.get(attrs, "topic", "")) |> to_string() |> String.trim()

    if name == "" do
      {:error, :empty_name}
    else
      room_id = unique_room_id(name)

      member_ids =
        Enum.uniq(
          Enum.map(channel_people(), & &1.id) ++
            Enum.map(Seeds.agent_people(), & &1.id) ++
            [Seeds.system_user_id()]
        )

      with {:ok, %{room: room} = provisioned} <-
             ChatRuntime.provision_room(@room_definition, %{
               id: room_id,
               kind: :channel,
               name: name,
               metadata: %{
                 "workspace_id" => Seeds.workspace_id(),
                 "assembly_kind" => "channel",
                 "topic" => blank_to_default(topic, "Group chat for #{name}."),
                 "member_ids" => member_ids,
                 "position" => System.system_time(:millisecond)
               }
             }),
           :ok <- join_members(room_id, member_ids),
           {:ok, message, signals} <-
             send_message_command(
               room_id,
               "Created ##{room.name}. Invite people by sharing this room.",
               Seeds.system_user_id(),
               role: :system,
               metadata: %{"source" => "jido_assembly"}
             ) do
        presence = presence_snapshot()

        {:ok, Projections.room_view(room, presence), [message],
         provision_signals(provisioned) ++ signals}
      end
    end
  end

  defp channel_people, do: if(Pilot.enabled?(), do: Pilot.people(), else: Seeds.demo_users())

  def room_views do
    ensure_seeded!()
    Projections.room_views(presence_snapshot())
  end

  def room_view(room), do: Projections.room_view(room, presence_snapshot())

  def error_to_string(:empty_message), do: "Type a message first."
  def error_to_string(:empty_name), do: "Name the group chat first."
  def error_to_string(:not_found), do: "That room is no longer available."
  def error_to_string(:invalid_thread), do: "That reply does not belong to this thread."
  def error_to_string(reason), do: "Something went wrong: #{inspect(reason)}"

  @doc false
  defdelegate message_record(record), to: Projections

  defp post(room_id, body, content, sender_id, opts) do
    role = Keyword.get(opts, :role, :user)

    metadata =
      %{
        "workspace_id" => Seeds.workspace_id(),
        "source" => "jido_assembly",
        "role" => Atom.to_string(role)
      }
      |> Map.merge(stringify_keys(Keyword.get(opts, :metadata, %{})))
      |> Map.merge(stringify_keys(Mentions.metadata(body)))
      |> put_origin(sender_id, role)

    post =
      Post.new(%{
        content: content,
        thread_id: opts[:thread_id],
        reply_to_id: opts[:reply_to_id] || opts[:thread_id],
        mentions: Mentions.mentioned_user_ids(body),
        metadata: metadata
      })

    signal_opts = if opts[:message_id], do: [id: opts[:message_id]], else: []

    request =
      PostSignal.new!(
        %{"post" => Post.to_map(post), "mentions" => post.mentions},
        signal_opts
      )

    room_call(room_id, request, sender_id)
  end

  defp room_call(room_id, request, actor) do
    with {:ok, address} <- Jido.agent_address(ChatRuntime.jido(), room_id),
         {:ok, %Jido.AgentServer.TurnResult{} = result} <-
           Jido.call(ChatRuntime.jido(), address, request, context: %{actor: actor}),
         :ok <- committed(result) do
      {:ok, result}
    end
  end

  defp committed(%Jido.AgentServer.TurnResult{status: :committed}), do: :ok

  defp committed(%Jido.AgentServer.TurnResult{status: status, error: reason}),
    do: {:error, {status, reason}}

  defp committed_signals(%Jido.AgentServer.TurnResult{reply: nil}), do: []

  defp committed_signals(%Jido.AgentServer.TurnResult{reply: reply}) do
    case reply.data do
      %{"message" => %Jido.Signal{} = message_fact} -> [message_fact, reply]
      _data -> [reply]
    end
  end

  defp reply_message_id(%Jido.AgentServer.TurnResult{reply: %{data: %{"message" => %{id: id}}}}),
    do: id

  defp provision_signals(%{activation: {:ok, _status}}), do: []
  defp provision_signals(_result), do: []

  defp join_members(room_id, member_ids) do
    Enum.reduce_while(member_ids, :ok, fn member, :ok ->
      request = Join.new!(%{"member" => member})

      case room_call(room_id, request, Seeds.current_user_id()) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_thread(_room_id, nil, nil), do: :ok
  defp ensure_thread(_room_id, nil, _parent_id), do: {:error, :invalid_thread}

  defp ensure_thread(room_id, root_id, parent_id) do
    case ChatRuntime.get_room_history(room_id, root_id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{thread_id: nil}} ->
        ensure_thread_parent(room_id, root_id, parent_id)

      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{}} ->
        {:error, :invalid_thread}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_thread_parent(_room_id, _root_id, nil), do: :ok
  defp ensure_thread_parent(_room_id, root_id, root_id), do: :ok

  defp ensure_thread_parent(room_id, root_id, parent_id) do
    case ChatRuntime.get_room_history(room_id, parent_id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{thread_id: ^root_id}} -> :ok
      {:ok, _other} -> {:error, :invalid_thread}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_history(message_id) do
    ChatRuntime.list_rooms(limit: 500)
    |> case do
      {:ok, rooms} -> find_history_in_rooms(rooms, message_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_history_in_rooms(rooms, message_id) do
    Enum.reduce_while(rooms, {:error, :not_found}, fn room, _result ->
      case ChatRuntime.get_room_history(room.id, message_id) do
        {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{} = record} -> {:halt, {:ok, record}}
        _other -> {:cont, {:error, :not_found}}
      end
    end)
  end

  defp put_origin(metadata, sender_id, role) do
    person = Seeds.person_seed(sender_id)

    kind =
      case role do
        :assistant -> :agent
        :system -> :system
        _role -> :human
      end

    actor =
      Actor.new(%{
        id: sender_id,
        kind: kind,
        username: Map.get(person, :handle),
        display_name: Map.get(person, :name)
      })

    Map.put(metadata, "jido_chat_origin", %{"actor" => Actor.to_map(actor)})
  end

  defp project_room_data(rooms, user_id, presence) do
    Enum.reduce(rooms, {%{}, %{}, %{}}, fn room, {messages, threads, cursors} = acc ->
      case Projections.history_page(room.id, user_id, presence, nil) do
        {:ok, page} ->
          {Map.put(messages, room.id, page.messages), Map.put(threads, room.id, page.threads),
           Map.put(cursors, room.id, page.before)}

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp empty_snapshot(user_id, presence) do
    %{
      workspace: %{id: Seeds.workspace_id(), name: Seeds.workspace_name()},
      current_user: current_user(user_id, presence),
      release_work: ReleaseNotes.work_view(user_id),
      demo_users: demo_users(presence),
      presence: presence,
      reaction_options: reaction_options(),
      rooms: [],
      channels: [],
      direct_messages: [],
      messages_by_room: %{},
      threads_by_room: %{},
      history_cursors: %{},
      active_room: nil,
      active_room_id: nil,
      active_room_name: "No Rooms",
      active_room_kind: "channel",
      active_room_prefix: "#",
      active_topic: "Create a Room to start.",
      connector_snapshot: Bridges.snapshot(nil),
      messages: [],
      member_count_label: "0 members",
      inspector: Inspector.snapshot(nil, [], %{}, [])
    }
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

    case ChatRuntime.get_room(base) do
      {:error, :not_found} -> base
      {:ok, _room} -> "#{base}-#{System.unique_integer([:positive])}"
      _other -> base
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

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
