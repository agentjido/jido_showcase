defmodule Jido.Assembly.Chat.MentionsTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.Chat
  alias Jido.Assembly.Chat.Mentions
  alias Jido.Assembly.Messaging

  setup do
    Chat.ensure_seeded!()
    :ok
  end

  test "resolves Assembly handles through persisted participants" do
    [mention] = Mentions.parse("hey @priya, can you check this?")

    assert mention.user_id == "user:priya"
    assert mention.username == "priya"
    assert mention.display_name == "Priya"
    assert mention.mention_text == "@priya"
    assert mention.metadata.offset == 4
    assert mention.metadata.length == 6
  end

  test "resolves custom participant handles without seed data" do
    suffix = System.unique_integer([:positive])
    participant_id = "user:dev-#{suffix}"
    handle = "dev#{suffix}"

    assert {:ok, _participant} =
             Messaging.create_participant(%{
               id: participant_id,
               type: :human,
               identity: %{name: "Developer #{suffix}", handle: handle},
               presence: :online,
               capabilities: [:text]
             })

    assert %{
             mentions: [^participant_id],
             mention_handles: [^handle]
           } = Mentions.metadata("Can @#{String.upcase(handle)} and @#{handle} review this?")
  end

  test "ignores email addresses and system handles" do
    refute "user:maggie" in Mentions.mentioned_user_ids("send this to maggie@example.com")
    assert Mentions.mentioned_user_ids("@assembly please archive this") == []
  end
end
