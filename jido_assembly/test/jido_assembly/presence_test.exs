defmodule Jido.Assembly.PresenceTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Chat, Messaging, Presence}

  @ops_room "room:ops-workflow"

  setup do
    Presence.reset()

    on_exit(fn ->
      Presence.reset()
    end)

    :ok
  end

  test "touch_presence tracks a participant and emits normalized Jido Messaging signals" do
    {:ok, subscription_id} = Messaging.subscribe_signals("jido.messaging.**")

    assert {:ok, presence, signals} =
             Chat.touch_presence("user:maggie", @ops_room, session_id: "presence-test")

    assert "user:maggie" in presence.online_user_ids
    assert Presence.online?("user:maggie")

    assert Enum.map(signals, & &1.type) == [
             "jido.messaging.room.participant_joined",
             "jido.messaging.participant.presence_changed"
           ]

    assert_receive {:signal, joined}
    assert joined.type == "jido.messaging.room.participant_joined"
    assert joined.data["participant_id"] == "user:maggie"
    assert joined.data["source"] == "jido_assembly.presence"

    assert_receive {:signal, changed}
    assert changed.type == "jido.messaging.participant.presence_changed"
    assert changed.data["from"] == :offline
    assert changed.data["to"] == :online

    assert {:ok, refreshed, []} =
             Chat.touch_presence("user:maggie", @ops_room, session_id: "presence-test")

    assert "user:maggie" in refreshed.online_user_ids

    assert {:ok, left_presence, left_signals} = Presence.mark_left("user:maggie", reason: :test)

    refute "user:maggie" in left_presence.online_user_ids

    assert Enum.map(left_signals, & &1.type) == [
             "jido.messaging.room.participant_left",
             "jido.messaging.participant.presence_changed"
           ]

    :ok = Messaging.unsubscribe_signals(subscription_id)
  end
end
