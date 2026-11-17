defmodule Jido.Assembly.Chat do
  @moduledoc """
  One-workspace chat context for the Assembly V3 showcase.

  Jido Chat Runtime owns durable Rooms, memberships, messages, reactions, and
  turn evidence. Assembly owns display profiles, search, and UI projections.
  """

  alias Jido.Assembly.Chat.{Mentions, Projections}
  alias Jido.Assembly.{Bridges, ChatRuntime, Inspector, Presence, Seeds}
  alias Jido.Chat.Actor
  alias Jido.Chat.Runtime.Room.Reaction

  alias Jido.Chat.Runtime.Signal.Room.{AddReaction, Join, RemoveReaction}
  alias Jido.Chat.Runtime.Signal.Room.Post, as: PostSignal

  @room_definition "assembly.room.v1"

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

    if active_room do
      {messages_by_room, threads_by_room} = project_room_data(rooms, user_id, presence)
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

  def send_message(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ []) do
    case send_message_command(room_id, body, sender_id, opts) do
      {:ok, message, _signals} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message_command(room_id, body, sender_id \\ Seeds.current_user_id(), opts \\ [])
      when is_binary(room_id) do
    ensure_seeded!()
    body = body |> to_string() |> String.trim()

    if body == "" do
      {:error, :empty_message}
    else
      with {:ok, _room} <- ChatRuntime.get_room(room_id),
           :ok <- ensure_thread(room_id, opts[:thread_id]),
           {:ok, result} <- post(room_id, body, sender_id, opts),
           {:ok, record} <- ChatRuntime.get_room_history(room_id, reply_message_id(result)) do
        {:ok,
         Projections.message_view_with_reply_count(
           message_record(record),
           sender_id,
           presence_snapshot()
         ), committed_signals(result)}
      end
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
           ChatRuntime.get_room_reaction(record.room_id, message_id, emoji, user_id),
         module =
           if(match?(%Reaction{status: :active}, current), do: RemoveReaction, else: AddReaction),
         request <- module.new!(%{"message_id" => message_id, "reaction" => emoji}),
         {:ok, result} <- room_call(record.room_id, request, user_id),
         {:ok, stored} <- ChatRuntime.get_room_history(record.room_id, message_id) do
      {:ok,
       Projections.message_view_with_reply_count(
         message_record(stored),
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
          Seeds.demo_user_ids() ++
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

  def room_views do
    ensure_seeded!()
    Projections.room_views(presence_snapshot())
  end

  def room_view(room), do: Projections.room_view(room, presence_snapshot())

  def error_to_string(:empty_message), do: "Type a message first."
  def error_to_string(:empty_name), do: "Name the group chat first."
  def error_to_string(:not_found), do: "That room is no longer available."
  def error_to_string(reason), do: "Something went wrong: #{inspect(reason)}"

  @doc false
  defdelegate message_record(record), to: Projections

  defp post(room_id, body, sender_id, opts) do
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
      Jido.Chat.Post.text(body,
        thread_id: opts[:thread_id],
        reply_to_id: opts[:reply_to_id] || opts[:thread_id],
        mentions: Mentions.mentioned_user_ids(body),
        metadata: metadata
      )

    request =
      PostSignal.new!(%{
        "post" => Jido.Chat.Post.to_map(post),
        "mentions" => post.mentions
      })

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

  defp ensure_thread(_room_id, nil), do: :ok

  defp ensure_thread(room_id, root_message_id) do
    case ChatRuntime.get_room_history(room_id, root_message_id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{}} -> :ok
      {:ok, nil} -> {:error, :not_found}
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
    Enum.reduce(rooms, {%{}, %{}}, fn room, {messages_acc, threads_acc} ->
      {messages, threads} = Projections.room_message_data(room.id, user_id, presence)
      {Map.put(messages_acc, room.id, messages), Map.put(threads_acc, room.id, threads)}
    end)
  end

  defp empty_snapshot(user_id, presence) do
    %{
      workspace: %{id: Seeds.workspace_id(), name: Seeds.workspace_name()},
      current_user: current_user(user_id, presence),
      demo_users: demo_users(presence),
      presence: presence,
      reaction_options: reaction_options(),
      rooms: [],
      channels: [],
      direct_messages: [],
      messages_by_room: %{},
      threads_by_room: %{},
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
