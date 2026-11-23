defmodule Jido.Assembly.ChatTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Chat, ChatRuntime, Seeds}

  @ops_room "room:ops-workflow"

  test "snapshot exposes one workspace with group chats and DMs" do
    snapshot = Chat.snapshot()

    assert snapshot.workspace.name == "Jido Assembly"
    assert snapshot.active_room_id == @ops_room
    assert Enum.any?(snapshot.channels, &(&1.id == @ops_room))
    assert Enum.any?(snapshot.channels, &(&1.id == "room:runtime"))
    assert Enum.any?(snapshot.channels, &(&1.id == "room:connector-lab"))
    assert Enum.any?(snapshot.direct_messages, &(&1.id == "dm:maggie"))
    assert Enum.any?(snapshot.direct_messages, &(&1.id == "dm:triage"))
    assert snapshot.connector_snapshot.headline == "Demo connectors"
    assert Map.has_key?(snapshot.messages_by_room, snapshot.active_room_id)
  end

  test "snapshot exposes the developer inspector stack" do
    inspector = Chat.snapshot().inspector

    stack_names = Enum.map(inspector.stack, & &1.name)
    assert "Hologram" in stack_names
    assert "Jido Chat Runtime" in stack_names
    assert "Jido Signal" in stack_names
    assert "Jido Chat Adapters" in stack_names
    assert "Jido" in stack_names

    assert Enum.any?(inspector.chat_contract, &(&1.detail == "Jido.Chat.Runtime.Room.Record"))
    assert Enum.any?(inspector.capabilities, &(&1.feature == "Threads"))
    assert Enum.any?(inspector.capabilities, &(&1.feature == "Signals"))
  end

  test "boot seeding is idempotent and keeps durable V3 Rooms" do
    assert :ok = Seeds.ensure_seeded!()
    assert :ok = Seeds.ensure_seeded!()
    assert {:ok, room} = ChatRuntime.get_room(@ops_room)
    assert room.metadata["source_key"] == "seed/room/room:ops-workflow"
    assert {:ok, %{state: :running}} = ChatRuntime.room_runtime_status(@ops_room)
    assert Enum.any?(Chat.snapshot().channels, &(&1.id == @ops_room))
  end

  test "send_message persists through the Jido Chat Runtime" do
    body = "test message #{System.unique_integer([:positive])}"

    assert {:ok, message} = Chat.send_message(@ops_room, body)
    assert message.body == body
    assert message.own

    assert Enum.any?(Chat.list_message_views(@ops_room), &(&1.id == message.id))
  end

  test "create_channel creates a new group chat with an initial system message" do
    name = "spike-#{System.unique_integer([:positive])}"

    assert {:ok, room, [message]} = Chat.create_channel(%{name: name, topic: "Test room"})
    assert room.kind == "channel"
    assert room.name == name
    assert message.room_id == room.id
    assert Enum.any?(Chat.room_views(), &(&1.id == room.id))
  end

  test "send_message supports demo users and mention metadata" do
    body = "@priya can you look at this? #{System.unique_integer([:positive])}"

    assert {:ok, message} = Chat.send_message(@ops_room, body, "user:maggie")
    assert message.sender_id == "user:maggie"
    assert message.author == "Maggie"
    assert "user:priya" in message.mentioned_user_ids

    assert {:ok, record} = ChatRuntime.get_room_history(@ops_room, message.id)
    assert Chat.message_record(record).metadata["mention_handles"] == ["priya"]
  end

  test "send_message resolves agent mentions through persisted participants" do
    body = "@triage can you review this? #{System.unique_integer([:positive])}"

    assert {:ok, message} = Chat.send_message(@ops_room, body, "user:you")
    assert "agent:triage" in message.mentioned_user_ids

    assert {:ok, record} = ChatRuntime.get_room_history(@ops_room, message.id)
    assert Chat.message_record(record).metadata["mention_handles"] == ["triage"]
  end

  test "toggle_reaction persists reaction state on messages" do
    body = "reaction target #{System.unique_integer([:positive])}"
    assert {:ok, message} = Chat.send_message(@ops_room, body)

    assert {:ok, reacted} = Chat.toggle_reaction(message.id, "+1", "user:maggie")

    assert [
             %{
               emoji: "+1",
               glyph: "👍",
               label: "Agree",
               count: 1,
               user_ids: ["user:maggie"]
             }
           ] = reacted.reactions

    assert {:ok, unreacted} = Chat.toggle_reaction(message.id, "+1", "user:maggie")
    assert unreacted.reactions == []
  end

  test "writes emit committed V3 facts on the Runtime Bus" do
    room_id = @ops_room
    {:ok, message_subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    {:ok, reaction_subscription} = ChatRuntime.subscribe_runtime("jido.chat.reaction.*")

    body = "event target #{System.unique_integer([:positive])}"

    assert {:ok, message, [message_signal, command_reply]} =
             Chat.send_message_command(room_id, body)

    assert message_signal.type == "jido.chat.room.message"
    assert message_signal.id == message.id
    assert command_reply.type == "jido.chat.room.posted"

    message_id = message.id

    assert_receive {:signal, %{type: "jido.chat.room.message", id: ^message_id}}, 1_000

    assert {:ok, %{id: ^message_id}, [_reaction_reply]} =
             Chat.toggle_reaction_command(message_id, "+1", "user:maggie")

    assert_receive {:signal,
                    %{
                      type: "jido.chat.reaction.added",
                      data: %{"message_id" => ^message_id, "actor_id" => "user:maggie"}
                    }},
                   1_000

    assert {:ok, _unreacted, [remove_signal]} =
             Chat.toggle_reaction_command(message_id, "+1", "user:maggie")

    assert remove_signal.type == "jido.chat.room.reaction.changed"

    assert_receive {:signal,
                    %{
                      type: "jido.chat.reaction.removed",
                      data: %{"message_id" => ^message_id, "actor_id" => "user:maggie"}
                    }},
                   1_000

    :ok = ChatRuntime.unsubscribe_runtime(message_subscription)
    :ok = ChatRuntime.unsubscribe_runtime(reaction_subscription)
  end

  test "thread replies are listed under the root message" do
    root_body = "thread root #{System.unique_integer([:positive])}"
    assert {:ok, root} = Chat.send_message(@ops_room, root_body)

    assert {:ok, reply} =
             Chat.send_message(@ops_room, "reply body", "user:nolan",
               thread_id: root.id,
               reply_to_id: root.id
             )

    refute Enum.any?(Chat.list_message_views(@ops_room), &(&1.id == reply.id))

    assert [%{id: reply_id}] = Chat.list_thread_views(@ops_room, root.id)
    assert reply_id == reply.id

    assert %{reply_count: 1} =
             Chat.list_message_views(@ops_room)
             |> Enum.find(&(&1.id == root.id))
  end

  test "search returns matching messages across the workspace" do
    unique = "needle-#{System.unique_integer([:positive])}"
    assert {:ok, message} = Chat.send_message("room:runtime", unique, "user:priya")

    assert [%{message_id: message_id, room_id: "room:runtime"} | _] = Chat.search(unique)
    assert message_id == message.id
  end
end
