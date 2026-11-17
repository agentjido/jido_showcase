defmodule Jido.Assembly.PresenceTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Chat, Presence}

  @ops_room "room:ops-workflow"

  setup do
    Presence.reset()

    on_exit(fn ->
      Presence.reset()
    end)

    :ok
  end

  test "touch_presence tracks a browser session and emits Assembly presence signals" do
    assert {:ok, presence, signals} =
             Chat.touch_presence("user:maggie", @ops_room, session_id: "presence-test")

    assert "user:maggie" in presence.online_user_ids
    assert Presence.online?("user:maggie")

    assert Enum.map(signals, & &1.type) == [
             "jido.assembly.presence.joined",
             "jido.assembly.presence.changed"
           ]

    [joined, changed] = signals
    assert joined.data.user_id == "user:maggie"
    assert joined.data.room_id == @ops_room
    assert changed.data.from == "offline"
    assert changed.data.to == "online"

    assert {:ok, refreshed, []} =
             Chat.touch_presence("user:maggie", @ops_room, session_id: "presence-test")

    assert "user:maggie" in refreshed.online_user_ids

    assert {:ok, left_presence, left_signals} = Presence.mark_left("user:maggie", reason: :test)

    refute "user:maggie" in left_presence.online_user_ids

    assert Enum.map(left_signals, & &1.type) == [
             "jido.assembly.presence.left",
             "jido.assembly.presence.changed"
           ]
  end
end
