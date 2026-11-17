defmodule Jido.AssemblyWeb.RuntimeNotifierTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.Chat
  alias Jido.AssemblyWeb.RuntimeNotifier

  @ops_room "room:ops-workflow"

  test "message_saved_params reads a committed Runtime fact from durable storage" do
    body = "notifier projection #{System.unique_integer([:positive])}"

    assert {:ok, message, [message_fact, _command_reply]} =
             Chat.send_message_command(@ops_room, body, "user:maggie")

    assert {:ok, params} = RuntimeNotifier.message_saved_params(message_fact)

    assert params.room_id == @ops_room
    assert params.message.id == message.id
    assert params.message.body == body
    assert params.message.author == "Maggie"
    assert params.connector_snapshot.headline in ["Demo connectors", "Telegram + Discord live"]
    assert params.signal.type == "jido.chat.room.message"
    assert params.signal.id == message.id
  end
end
