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

  @tag scenario: "CH08"
  test "a player stays online until their last session closes" do
    user = "user:eli"
    assert {:ok, _, [_joined, _changed]} = Chat.touch_presence(user, @ops_room, session_id: "one")
    assert {:ok, _, []} = Chat.touch_presence(user, @ops_room, session_id: "two")

    assert {:ok, %{sessions: [%{session_id: "two"}]}, []} =
             Presence.mark_left(user, session_id: "one")

    assert Presence.online?(user)
    assert {:ok, %{sessions: []}, [left, changed]} = Presence.mark_left(user, session_id: "two")
    refute Presence.online?(user)
    assert left.type == "jido.assembly.presence.left"
    assert changed.data.to == "offline"
  end
end
