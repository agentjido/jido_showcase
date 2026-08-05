defmodule Jido.AssemblyWeb.MessagingNotifierTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.Chat
  alias Jido.AssemblyWeb.MessagingNotifier

  @ops_room "room:ops-workflow"

  test "message_saved_params projects committed messaging signals into Hologram actions" do
    body = "notifier projection #{System.unique_integer([:positive])}"

    assert {:ok, message, [signal]} =
             Chat.send_message_command(@ops_room, body, "user:maggie")

    assert {:ok, params} = MessagingNotifier.message_saved_params(signal)

    assert params.room_id == @ops_room
    assert params.message.id == message.id
    assert params.message.body == body
    assert params.message.author == "Maggie"
    assert params.connector_snapshot.headline in ["Demo connectors", "Telegram + Discord live"]
    assert params.signal.type == "jido.messaging.room.message_added"
    assert params.signal.message_id == message.id
  end
end
