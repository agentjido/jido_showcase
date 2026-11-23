defmodule Jido.Assembly.MultiplayerTest do
  use Jido.Assembly.HologramPageCase, async: false

  alias Hologram.Server.Broadcast
  alias Jido.Assembly.{Agents, Chat, ChatRuntime, ChatStorage, ScriptedInference, Seeds}
  alias Jido.Assembly.Pages.Assembly
  alias Jido.AssemblyWeb.RuntimeNotifier

  @you "user:you"
  @maggie "user:maggie"
  @triage "agent:triage"
  @bridge "agent:bridge"
  @runbook "agent:runbook"

  @tag scenario: "CH01"
  test "two players see the same committed post with the correct ownership" do
    room_id = room!()
    {sender, sender_server} = player(@you, room_id)
    {peer, _peer_server} = player(@maggie, room_id)
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    body = "The release candidate is ready."
    command = Assembly.action(:send_message, %{"body" => body}, sender).next_command

    assert command.params.sender_id == @you
    assert command.params.room_id == room_id

    %{message: %{id: id}} = broadcast!(command.name, command.params, sender_server)
    assert_receive {:signal, %Jido.Signal{id: ^id} = signal}, 1_000
    assert {:ok, record} = ChatRuntime.get_room_history(room_id, id)
    assert Chat.message_record(record).sender_id == @you
    assert {:ok, params} = RuntimeNotifier.message_saved_params(signal)

    sender = Assembly.action(:message_saved, params, sender)
    peer = Assembly.action(:message_saved, params, peer)
    assert %{id: ^id, body: ^body, time: time, own: true} = timeline_message(sender, id)
    assert is_binary(time) and time != ""
    assert %{id: ^id, body: ^body, time: ^time, own: false} = timeline_message(peer, id)
  end

  @tag scenario: "CH02"
  test "Maya's mention marks the release post for Eli only" do
    room_id = Seeds.release_room_id()
    {maya, server} = player("user:maya", room_id)
    {eli, _server} = player("user:eli", room_id)

    command =
      Assembly.action(:send_message, %{"body" => "Review the candidate, @eli."}, maya).next_command

    %{message: %{id: id}} = params = broadcast!(command.name, command.params, server)
    maya = Assembly.action(:message_saved, params, maya)
    eli = Assembly.action(:message_saved, params, eli)

    assert %{mentions_current_user: false} = timeline_message(maya, id)
    assert %{mentions_current_user: true} = timeline_message(eli, id)
    assert {:ok, record} = ChatRuntime.get_room_history(room_id, id)
    assert %{"mentions" => ["user:eli"]} = Chat.message_record(record).metadata
  end

  @tag scenario: "CH03"
  test "a blank composer submission changes neither history nor published messages" do
    room_id = room!()
    {sender, server} = player(@you, room_id)
    assert {:ok, history} = ChatRuntime.list_room_history(room_id)
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    sender = Assembly.action(:send_message, %{"body" => "  \n "}, sender)
    assert sender.state.error == "Type a message first."
    refute sender.next_command

    rejected =
      Assembly.command(:persist_message, %{room_id: room_id, body: "  ", sender_id: @you}, server)

    assert rejected.next_action.name == :send_failed
    assert rejected.broadcasts == []
    assert {:ok, ^history} = ChatRuntime.list_room_history(room_id)
    refute_new_message_event(room_id, List.last(history).sequence)
  end

  @tag scenario: "CH04"
  test "a post to an inactive room adds one unread item even when its event is replayed" do
    room_id = room!()
    {sender, server} = player(@you, room_id)
    {peer, _server} = player(@maggie, Chat.default_room_id())

    command =
      Assembly.action(:send_message, %{"body" => "The release status changed."}, sender).next_command

    %{message: %{id: id}} = params = broadcast!(command.name, command.params, server)
    peer = Assembly.action(:message_saved, params, peer)
    peer = Assembly.action(:message_saved, params, peer)

    assert %{unread: 1, mention_unread: 0} = room_view(peer, room_id)
    refute timeline_message(peer, id)

    peer = Assembly.action(:select_room, %{id: room_id}, peer)
    assert %{id: ^id, body: "The release status changed."} = timeline_message(peer, id)
    assert Enum.count(peer.state.messages, &(&1.id == id)) == 1
  end

  @tag scenario: "CH05"
  test "a mention contributes to both unread counters only for its recipient" do
    room_id = room!()
    {maggie, _server} = player(@maggie, Chat.default_room_id())
    {you, server} = player(@you, Chat.default_room_id())

    saved =
      for body <- ["Release is ready.", "The branch is frozen.", "@maggie review the note."] do
        broadcast!(:persist_message, %{room_id: room_id, body: body, sender_id: @you}, server)
      end

    assert %{unread: 3, mention_unread: 1} = room_view(apply_posts(maggie, saved), room_id)
    assert %{unread: 0, mention_unread: 0} = room_view(apply_posts(you, saved), room_id)
  end

  @tag scenario: "CH06"
  test "opening a room clears only that room for the player who opened it" do
    room_id = room!()
    other_room_id = room!()
    {you, _server} = player(@you, Chat.default_room_id())
    {maggie, _server} = player(@maggie, Chat.default_room_id())
    {_nolan, server} = player("user:nolan", Chat.default_room_id())

    saved =
      for id <- [room_id, other_room_id] do
        broadcast!(
          :persist_message,
          %{room_id: id, body: "@you @maggie please check.", sender_id: "user:nolan"},
          server
        )
      end

    you = apply_posts(you, saved)
    maggie = apply_posts(maggie, saved)
    assert %{unread: 1, mention_unread: 1} = room_view(you, room_id)

    you = Assembly.action(:select_room, %{id: room_id}, you)
    assert %{unread: 0, mention_unread: 0} = room_view(you, room_id)
    assert %{unread: 1, mention_unread: 1} = room_view(you, other_room_id)
    assert %{unread: 1, mention_unread: 1} = room_view(maggie, room_id)
  end

  @tag scenario: "CH07"
  test "returning to a room fills missed history in order and keeps newer events once" do
    room_id = room!()
    {peer, server} = player(@maggie, Chat.default_room_id())

    first = post!(room_id, "First while Maggie is offline.")
    second = post!(room_id, "Second while Maggie is offline.")

    peer = Assembly.action(:select_room, %{id: room_id}, peer)
    command = peer.next_command
    response = Assembly.command(command.name, command.params, server).next_action

    %{message: third} =
      live =
      broadcast!(
        :persist_message,
        %{room_id: room_id, body: "A newer post arrives during catch-up.", sender_id: @you},
        server
      )

    peer = Assembly.action(:message_saved, live, peer)
    peer = Assembly.action(response.name, response.params, peer)
    peer = Assembly.action(:message_saved, live, peer)
    ids = Enum.map(peer.state.messages, & &1.id)

    assert Enum.take(ids, -3) == [first.id, second.id, third.id]
    assert ids == Enum.uniq(ids)
  end

  @tag scenario: "CH09"
  test "channel creation gives two players one room and one initial system post" do
    {you, server} = player(@you, Chat.default_room_id())
    {maggie, _server} = player(@maggie, Chat.default_room_id())
    name = "release-review-#{System.unique_integer([:positive])}"
    you = put_page_state(you, :new_room_name, name)
    command = Assembly.action(:create_channel, %{}, you).next_command
    created = Assembly.command(command.name, command.params, server)

    assert [%Broadcast{action_name: :room_created, params: params}] = created.broadcasts
    assert %{room: %{id: room_id, name: ^name}, messages: [%{id: initial_id}]} = params

    for page <- [you, maggie] do
      page = Assembly.action(:room_created, params, page)
      assert %{name: ^name} = room_view(page, room_id)
      assert [%{id: ^initial_id}] = page.state.messages_by_room[room_id]
    end

    assert {:ok, [record]} = ChatRuntime.list_room_history(room_id)
    assert %{id: ^initial_id, role: :system} = Chat.message_record(record)
    {reloaded, _server} = player(@maggie, room_id)
    assert reloaded.state.active_room_id == room_id
    assert [%{id: ^initial_id}] = reloaded.state.messages

    for sender <- ["user:maya", "user:eli"] do
      assert {:ok, %{status: :active}} = ChatRuntime.get_room_membership(room_id, sender)
      {page, server} = player(sender, room_id)
      command = Assembly.action(:send_message, %{"body" => "Ready to review."}, page).next_command

      assert %{message: %{id: message_id, sender_id: ^sender}} =
               broadcast!(command.name, command.params, server)

      assert {:ok, saved} = ChatRuntime.get_room_history(room_id, message_id)
      assert %{sender_id: ^sender} = Chat.message_record(saved)
    end
  end

  @tag scenario: "CH10"
  test "two DM participants share a private conversation outside the channel timeline" do
    dm_id = "dm:maggie"
    channel_id = Chat.default_room_id()
    {you, you_server} = player(@you, dm_id)
    {maggie, maggie_server} = player(@maggie, dm_id)
    you_channel = you.state.messages_by_room[channel_id]
    maggie_channel = maggie.state.messages_by_room[channel_id]

    command =
      Assembly.action(:send_message, %{"body" => "Can you review the release?"}, you).next_command

    %{message: %{id: root_id}} = post = broadcast!(command.name, command.params, you_server)
    you = Assembly.action(:message_saved, post, you)
    maggie = Assembly.action(:message_saved, post, maggie)
    you = Assembly.action(:open_thread, %{message_id: root_id}, you)
    maggie = Assembly.action(:open_thread, %{message_id: root_id}, maggie)

    command = Assembly.action(:send_reply, %{"reply" => "I can review it."}, maggie).next_command
    %{message: %{id: reply_id}} = reply = broadcast!(command.name, command.params, maggie_server)
    you = Assembly.action(:message_saved, reply, you)
    maggie = Assembly.action(:message_saved, reply, maggie)

    assert %{kind: "dm"} = room_view(you, dm_id)
    assert %{kind: "dm"} = room_view(maggie, dm_id)
    assert [%{id: ^reply_id, reply_to_id: ^root_id, own: false}] = you.state.thread_messages
    assert [%{id: ^reply_id, reply_to_id: ^root_id, own: true}] = maggie.state.thread_messages
    assert [%{id: ^reply_id}] = Chat.list_thread_views(dm_id, root_id, @you)
    assert you.state.messages_by_room[channel_id] == you_channel
    assert maggie.state.messages_by_room[channel_id] == maggie_channel
  end

  @tag scenario: "CH11"
  test "a nonmember cannot load, search, post to, or subscribe to a private DM" do
    room_id = "dm:maggie"
    phrase = "Private item #{System.unique_integer([:positive])}"
    {_, owner_server} = player(@you, room_id)

    owner_post =
      Assembly.command(
        :persist_message,
        %{room_id: room_id, sender_id: @you, body: phrase},
        owner_server
      )

    owner_event = Enum.find(owner_post.broadcasts, &(&1.action_name == :message_saved))
    assert owner_event
    assert {owner_event.channel, "page"} in owner_server.subscriptions

    {page, outsider} =
      init_page(Assembly, %{}, user_id: "user:nolan", session_id: "private-dm-outsider")

    refute room_view(page, room_id)
    refute {owner_event.channel, "page"} in outsider.subscriptions

    impersonate =
      Assembly.command(:switch_demo_user, %{id: @you, active_room_id: room_id}, outsider)

    assert impersonate.next_action.name == :room_access_denied
    refute {owner_event.channel, "page"} in impersonate.subscriptions

    load =
      Assembly.command(
        :load_room_history,
        %{room_id: room_id, user_id: @you},
        outsider
      )

    assert load.next_action.name == :room_access_denied

    search = Assembly.command(:run_search, %{query: phrase, user_id: @you}, outsider)
    assert search.next_action.params.results == []

    rejected =
      Assembly.command(
        :persist_message,
        %{room_id: room_id, sender_id: @you, body: "Forged private reply"},
        outsider
      )

    assert rejected.next_action.name == :send_failed
    assert rejected.broadcasts == []
    refute Enum.any?(Chat.list_message_views(room_id, @you), &(&1.body == "Forged private reply"))
  end

  @tag scenario: "CH12"
  test "search opens the result's room and marks the exact post for browser focus" do
    room_id = room!()
    phrase = "Search target #{System.unique_integer([:positive])}"
    result = post!(room_id, phrase)
    later = post!(room_id, "A different post follows the search target.")
    {page, server} = player(@maggie, Chat.default_room_id())
    page = Assembly.action(:search_changed, %{"value" => phrase}, page)
    search = page.next_command
    response = Assembly.command(search.name, search.params, server).next_action
    page = Assembly.action(response.name, response.params, page)

    assert [%{room_id: ^room_id, message_id: id, thread_id: nil} = hit] =
             page.state.search_results

    assert id == result.id

    page = Assembly.action(:select_search_result, hit, page)
    assert page.state.active_room_id == room_id
    assert page.state.focused_message_id == result.id
    assert timeline_message(page, later.id)
    assert page.state.search_results == []
  end

  @tag scenario: "TH01"
  test "the first reply has the root as its thread and parent for both players" do
    room_id = room!()
    root = post!(room_id, "Candidate discussion")
    reply = post!(room_id, "CI has passed.", @maggie, thread_id: root.id)
    assert {:ok, record} = ChatRuntime.get_room_history(room_id, reply.id)
    root_id = root.id
    assert %{thread_id: ^root_id, reply_to_id: ^root_id} = Chat.message_record(record)

    for user <- [@you, @maggie] do
      {page, _server} = player(user, room_id)
      assert %{reply_count: 1} = timeline_message(page, root_id)
    end
  end

  @tag scenario: "TH04"
  test "a reply reaches both open threads with the correct author" do
    room_id = room!()
    root = post!(room_id, "Release review")
    {sender, _sender_server} = player(@you, room_id)
    {peer, peer_server} = player(@maggie, room_id)
    sender = Assembly.action(:open_thread, %{message_id: root.id}, sender)
    peer = Assembly.action(:open_thread, %{message_id: root.id}, peer)

    command =
      Assembly.action(:send_reply, %{"reply" => "Checked the release."}, peer).next_command

    %{message: %{id: id}} = params = broadcast!(command.name, command.params, peer_server)
    sender = Assembly.action(:message_saved, params, sender)
    peer = Assembly.action(:message_saved, params, peer)

    assert [%{id: ^id, own: false, author: "Maggie", reply_to_id: parent}] =
             sender.state.thread_messages

    assert parent == root.id
    assert [%{id: ^id, own: true, author: "Maggie"}] = peer.state.thread_messages
    assert %{reply_count: 1} = timeline_message(sender, root.id)
    refute timeline_message(sender, id)
    refute timeline_message(peer, id)
    assert [%{id: ^id, sender_id: @maggie}] = Chat.list_thread_views(room_id, root.id, @you)
  end

  @tag scenario: "TH03"
  test "a reply changes the thread count and leaves the room timeline count unchanged" do
    room_id = room!()
    root = post!(room_id, "Release review")
    {page, server} = player(@maggie, room_id)
    before = page.state.message_count

    %{message: %{id: id}} =
      params =
      broadcast!(
        :persist_reply,
        %{room_id: room_id, root_message_id: root.id, body: "Reviewed.", sender_id: @maggie},
        server
      )

    page = Assembly.action(:message_saved, params, page)
    assert page.state.message_count == before
    refute timeline_message(page, id)
    assert %{reply_count: 1} = timeline_message(page, root.id)
    assert length(Chat.list_message_views(room_id, @you)) == before
  end

  @tag scenario: "EM01"
  test "a fresh thread view preserves compound emoji in message text" do
    room_id = room!()
    root = post!(room_id, "Release discussion")
    body = "Reviewed 👩🏽‍💻, check passed ✅, recipient 🇨🇦."
    reply = post!(room_id, body, @maggie, thread_id: root.id)

    assert [%{id: id, body: ^body}] = Chat.list_thread_views(room_id, root.id, @you)
    assert id == reply.id
    assert {:ok, %{body: ^body}} = Chat.get_message_view(reply.id, @maggie)
  end

  @tag scenario: "TH05"
  test "identical sibling posts keep separate replies, counts, and links" do
    room_id = room!()
    first = post!(room_id, "Release discussion")
    second = post!(room_id, "Release discussion")
    first_reply = post!(room_id, "First result", @maggie, thread_id: first.id)
    second_reply = post!(room_id, "Second result", @maggie, thread_id: second.id)
    follow_up = post!(room_id, "Second update", @you, thread_id: second.id)
    {page, _server} = player(@maggie, room_id)

    assert %{reply_count: 1, permalink: first_link} = timeline_message(page, first.id)
    assert %{reply_count: 2, permalink: second_link} = timeline_message(page, second.id)
    refute first_link == second_link
    refute first_reply.permalink == second_reply.permalink

    for {root, reply, expected} <- [
          {first, first_reply, [first_reply.id]},
          {second, second_reply, [second_reply.id, follow_up.id]}
        ] do
      {linked, _server} = open_link(reply.permalink, @maggie)
      assert linked.state.thread_root.id == root.id
      assert Enum.map(linked.state.thread_messages, & &1.id) == expected
    end
  end

  @tag scenario: "TH06"
  test "simultaneous replies get unique IDs and keep canonical order on a fresh read" do
    room_id = room!()
    root = post!(room_id, "Concurrent review")

    results =
      [@you, @maggie]
      |> Task.async_stream(
        &Chat.send_message(room_id, "Reply from #{&1}", &1, thread_id: root.id),
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, {:ok, message}} -> message end)

    expected = results |> Enum.sort_by(& &1.sequence) |> Enum.map(& &1.id)
    assert length(Enum.uniq(expected)) == 2

    for user <- [@you, @maggie] do
      {page, _server} = player(user, room_id)
      page = Assembly.action(:open_thread, %{message_id: root.id}, page)
      assert Enum.map(page.state.thread_messages, & &1.id) == expected
    end
  end

  @tag scenario: "TH07"
  test "a nested reply permalink opens its exact thread and focus target in a fresh session" do
    room_id = room!()
    root = post!(room_id, "Release review")
    earlier = post!(room_id, "Earlier evidence.", @maggie, thread_id: root.id)

    target =
      post!(room_id, "The exact nested reply.", @you, thread_id: root.id, reply_to_id: earlier.id)

    later = post!(room_id, "A later comment.", @maggie, thread_id: root.id)
    {page, _server} = open_link(target.permalink, @maggie)

    assert page.state.active_room_id == room_id
    assert page.state.thread_open
    assert page.state.thread_root.id == root.id
    assert page.state.focused_message_id == target.id
    assert Enum.map(page.state.thread_messages, & &1.id) == [earlier.id, target.id, later.id]

    refreshed =
      Assembly.action(:snapshot_loaded, %{snapshot: Chat.snapshot(@maggie, room_id)}, page)

    assert refreshed.state.thread_root.id == root.id
    assert refreshed.state.focused_message_id == target.id
  end

  @tag scenario: "TH08"
  test "a reply search hit loads a missing thread and focuses that reply" do
    room_id = room!()
    {page, server} = player(@maggie, Chat.default_room_id())
    root = post!(room_id, "New release thread")
    phrase = "Reply evidence #{System.unique_integer([:positive])}"
    target = post!(room_id, phrase, @you, thread_id: root.id)
    post!(room_id, "Additional discussion", @maggie, thread_id: root.id)

    page = Assembly.action(:search_changed, %{"value" => phrase}, page)
    search = page.next_command
    response = Assembly.command(search.name, search.params, server).next_action
    page = Assembly.action(response.name, response.params, page)

    assert [%{message_id: id, thread_id: thread} = hit] = page.state.search_results
    assert id == target.id
    assert thread == root.id
    page = Assembly.action(:select_search_result, hit, page)
    load = page.next_command
    response = Assembly.command(load.name, load.params, server).next_action
    page = Assembly.action(response.name, response.params, page)

    assert page.state.thread_open
    assert page.state.thread_root.id == root.id
    assert page.state.focused_message_id == target.id
    assert Enum.any?(page.state.thread_messages, &(&1.id == target.id))
  end

  @tag scenario: "TH09"
  test "a foreign thread root cannot change either room or reveal foreign content" do
    room_id = room!()
    foreign_id = room!()
    root = post!(foreign_id, "Evidence for the other room")
    {_, server} = player(@maggie, room_id)
    assert {:ok, history} = ChatRuntime.list_room_history(room_id)
    assert {:ok, foreign_history} = ChatRuntime.list_room_history(foreign_id)

    response =
      Assembly.command(
        :persist_reply,
        %{room_id: room_id, root_message_id: root.id, body: "A misplaced reply."},
        server
      )

    assert response.next_action.name == :send_failed
    refute String.contains?(response.next_action.params.error, root.body)
    assert response.broadcasts == []
    assert {:ok, ^history} = ChatRuntime.list_room_history(room_id)
    assert {:ok, ^foreign_history} = ChatRuntime.list_room_history(foreign_id)
  end

  @tag scenario: "TH10"
  test "a reply cannot use a sibling thread's reply as its parent" do
    room_id = room!()
    first = post!(room_id, "First thread")
    second = post!(room_id, "Second thread")
    parent = post!(room_id, "A reply to the second thread.", @maggie, thread_id: second.id)
    assert {:ok, history} = ChatRuntime.list_room_history(room_id)
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    assert {:error, :invalid_thread} =
             Chat.send_message_command(room_id, "Misplaced reply", @you,
               thread_id: first.id,
               reply_to_id: parent.id
             )

    assert {:ok, ^history} = ChatRuntime.list_room_history(room_id)
    refute_new_message_event(room_id, List.last(history).sequence)
  end

  @tag scenario: "TH11"
  test "an old reply is linkable before paging and keeps its count and order after paging" do
    room_id = room!()
    root = post!(room_id, "Older release review")
    target = post!(room_id, "Old evidence.", @maggie, thread_id: root.id)

    for index <- 1..50 do
      post!(room_id, "Room post #{index}")
    end

    latest = post!(room_id, "New evidence.", @maggie, thread_id: root.id)
    {initial, _server} = player(@maggie, room_id)
    refute timeline_message(initial, root.id)
    initial_cursor = initial.state.history_cursors[room_id]
    assert is_binary(initial_cursor)

    {page, server} = open_link(target.permalink, @maggie)
    assert page.state.thread_root.id == root.id
    assert page.state.focused_message_id == target.id
    assert %{reply_count: 2} = timeline_message(page, root.id)
    assert page.state.history_cursors[room_id] == initial_cursor

    page = Assembly.action(:load_older_history, %{}, page)
    request = page.next_command
    assert request.params.before == initial_cursor
    response = Assembly.command(request.name, request.params, server).next_action
    page = Assembly.action(response.name, response.params, page)
    page = Assembly.action(response.name, response.params, page)

    assert page.state.history_cursors[room_id] == nil
    assert %{reply_count: 2} = timeline_message(page, root.id)
    assert Enum.map(page.state.thread_messages, & &1.id) == [target.id, latest.id]
    assert page.state.focused_message_id == target.id

    assert {:ok, history} = ChatRuntime.list_room_history(room_id)
    expected = for %{thread_id: nil, message_id: id} <- history, do: id
    assert Enum.map(page.state.messages, & &1.id) == expected

    refreshed =
      Assembly.action(:snapshot_loaded, %{snapshot: Chat.snapshot(@maggie, room_id)}, page)

    assert refreshed.state.thread_root.id == root.id
    assert refreshed.state.history_cursors[room_id] == nil
    assert Enum.map(refreshed.state.messages, & &1.id) == expected
  end

  @tag scenario: "TH12"
  test "reload recovers a missed reply and replay keeps one reply and one count" do
    room_id = room!()
    root = post!(room_id, "Release review")
    {stale, _server} = player(@maggie, room_id)
    stale = Assembly.action(:open_thread, %{message_id: root.id}, stale)
    assert stale.state.thread_messages == []

    assert {:ok, reply, signals} =
             Chat.send_message_command(room_id, "Reply while offline", @you, thread_id: root.id)

    signal = Enum.find(signals, &(&1.type == "jido.chat.room.message"))
    assert {:ok, notification} = RuntimeNotifier.message_saved_params(signal)
    page = Assembly.action(:snapshot_loaded, %{snapshot: Chat.snapshot(@maggie, room_id)}, stale)
    assert Enum.map(page.state.thread_messages, & &1.id) == [reply.id]

    replayed = Assembly.action(:message_saved, notification, page)
    assert Enum.map(replayed.state.thread_messages, & &1.id) == [reply.id]
    assert %{reply_count: 1} = timeline_message(replayed, root.id)
  end

  @tag scenario: "TH02"
  test "a reply to a reply retains both canonical thread and immediate parent" do
    room_id = room!()
    root = post!(room_id, "Release status")
    evidence = post!(room_id, "Provider checks attached.", @maggie, thread_id: root.id)

    follow_up =
      post!(room_id, "Thanks for the evidence.", @you,
        thread_id: root.id,
        reply_to_id: evidence.id
      )

    assert {:ok, record} = ChatRuntime.get_room_history(room_id, follow_up.id)
    assert %{thread_id: thread_id, reply_to_id: parent_id} = Chat.message_record(record)
    assert thread_id == root.id
    assert parent_id == evidence.id

    assert Enum.map(Chat.list_thread_views(room_id, root.id, @maggie), & &1.id) ==
             [evidence.id, follow_up.id]
  end

  @tag scenario: "EM02"
  test "Maya's root reaction reaches both players and stores her actor ID" do
    room_id = Seeds.release_room_id()
    root = post!(room_id, "Release reaction check", "user:maya")
    {maya, server} = player("user:maya", room_id)
    {eli, _server} = player("user:eli", room_id)

    saved = react!(maya, server, root.id, "seen")

    assert {:ok, [%{message_id: message_id, reaction: "seen", status: :active} = record]} =
             ChatRuntime.list_room_reactions(room_id, message_id: root.id)

    assert message_id == root.id
    assert Jido.Chat.Runtime.Room.Reaction.actor(record) == "user:maya"

    maya = Assembly.action(:reaction_saved, saved, maya)
    eli = Assembly.action(:reaction_saved, saved, eli)

    assert %{reactions: [%{count: 1, user_ids: ["user:maya"], reacted: true}]} =
             timeline_message(maya, root.id)

    assert %{reactions: [%{count: 1, user_ids: ["user:maya"], reacted: false}]} =
             timeline_message(eli, root.id)
  end

  @tag scenario: "EM03"
  test "a reaction on a reply leaves its root and sibling reply unchanged" do
    room_id = room!()
    root = post!(room_id, "Release evidence")
    reply = post!(room_id, "CI passed.", @maggie, thread_id: root.id)
    sibling = post!(room_id, "Live checks are pending.", @maggie, thread_id: root.id)

    {you, server} = player(@you, room_id)
    {maggie, _server} = player(@maggie, room_id)
    you = Assembly.action(:open_thread, %{message_id: root.id}, you)
    maggie = Assembly.action(:open_thread, %{message_id: root.id}, maggie)
    saved = react!(you, server, reply.id, "seen")
    maggie = Assembly.action(:reaction_saved, saved, maggie)

    assert {:ok, %{reactions: []}} = Chat.get_message_view(root.id, @maggie)
    assert maggie.state.thread_root.reactions == []

    assert [%{reactions: [%{reacted: false, count: 1}]}, %{reactions: []}] =
             maggie.state.thread_messages

    assert [
             %{id: reply_id, reactions: [%{emoji: "seen", count: 1, user_ids: [@you]}]},
             %{id: sibling_id, reactions: []}
           ] = Chat.list_thread_views(room_id, root.id, @maggie)

    assert reply_id == reply.id
    assert sibling_id == sibling.id
  end

  @tag scenario: "EM04"
  test "two players can add the same emoji and see both actor IDs" do
    room_id = room!()
    root = post!(room_id, "Ready to review")
    {you, your_server} = player(@you, room_id)
    {maggie, her_server} = player(@maggie, room_id)

    first = react!(you, your_server, root.id, "+1")
    maggie = Assembly.action(:reaction_saved, first, maggie)
    second = react!(maggie, her_server, root.id, "+1")

    for page <- [you, maggie] do
      page = Assembly.action(:reaction_saved, second, page)

      assert %{reactions: [%{count: 2, reacted: true, user_ids: ids}]} =
               timeline_message(page, root.id)

      assert Enum.sort(ids) == [@maggie, @you]
    end
  end

  @tag scenario: "EM05"
  test "removing one player's reaction preserves the other player's reaction in both views" do
    room_id = room!()
    root = post!(room_id, "Ready to review")
    assert {:ok, _} = Chat.toggle_reaction(root.id, "+1", @you)
    assert {:ok, _} = Chat.toggle_reaction(root.id, "+1", @maggie)
    {you, _server} = player(@you, room_id)
    {maggie, her_server} = player(@maggie, room_id)

    saved = react!(maggie, her_server, root.id, "+1", false)
    you = Assembly.action(:reaction_saved, saved, you)
    maggie = Assembly.action(:reaction_saved, saved, maggie)

    assert %{reactions: [%{count: 1, user_ids: [@you], reacted: true}]} =
             timeline_message(you, root.id)

    assert %{reactions: [%{count: 1, user_ids: [@you], reacted: false}]} =
             timeline_message(maggie, root.id)
  end

  @tag scenario: "EM06"
  test "removing one emoji preserves the other emoji and its count" do
    room_id = room!()
    root = post!(room_id, "Ready to review")
    assert {:ok, _} = Chat.toggle_reaction(root.id, "+1", @you)
    assert {:ok, _} = Chat.toggle_reaction(root.id, "seen", @you)
    assert {:ok, _} = Chat.toggle_reaction(root.id, "seen", @maggie)
    {you, server} = player(@you, room_id)

    saved = react!(you, server, root.id, "+1", false)
    you = Assembly.action(:reaction_saved, saved, you)

    assert %{reactions: [%{emoji: "seen", count: 2, reacted: true}]} =
             timeline_message(you, root.id)

    assert {:ok, [%{reaction: "seen"}, %{reaction: "seen"}]} =
             ChatRuntime.list_room_reactions(room_id, message_id: root.id)
  end

  @tag scenario: "EM07"
  test "replaying the same add command leaves one active reaction without a second broadcast" do
    room_id = room!()
    root = post!(room_id, "Review this result")
    {page, server} = player(@you, room_id)
    command = reaction_command(page, root.id, "seen", true)

    assert [%Broadcast{action_name: :reaction_saved}] =
             Assembly.command(command.name, command.params, server).broadcasts

    assert {:ok, [%{status: :active, revision: 1} = stored]} =
             ChatRuntime.list_room_reactions(room_id, message_id: root.id)

    replay = Assembly.command(command.name, command.params, server)
    assert replay.broadcasts == []

    assert %{name: :reaction_saved, params: %{message: %{reactions: [%{count: 1}]}}} =
             replay.next_action

    assert {:ok, [^stored]} = ChatRuntime.list_room_reactions(room_id, message_id: root.id)
  end

  @tag scenario: "EM08"
  test "replaying the same remove command keeps the stored reaction removed" do
    room_id = room!()
    root = post!(room_id, "Review complete")
    assert {:ok, _} = Chat.toggle_reaction(root.id, "seen", @you)
    {page, server} = player(@you, room_id)
    command = reaction_command(page, root.id, "seen", false)

    assert [%Broadcast{action_name: :reaction_saved, params: %{message: %{reactions: []}}}] =
             Assembly.command(command.name, command.params, server).broadcasts

    assert {:ok, %{status: :removed, revision: 2} = stored} =
             ChatRuntime.get_room_reaction(room_id, root.id, "seen", @you)

    replay = Assembly.command(command.name, command.params, server)
    assert replay.broadcasts == []
    assert %{name: :reaction_saved, params: %{message: %{reactions: []}}} = replay.next_action
    assert {:ok, []} = ChatRuntime.list_room_reactions(room_id, message_id: root.id)
    assert {:ok, ^stored} = ChatRuntime.get_room_reaction(room_id, root.id, "seen", @you)
  end

  @tag scenario: "EM09"
  test "fresh room and thread views restore reaction actors after SQLite restarts" do
    room_id = room!()
    root = post!(room_id, "Release evidence")
    reply = post!(room_id, "Checks passed", @maggie, thread_id: root.id)
    assert {:ok, _} = Chat.toggle_reaction(root.id, "+1", @you)
    assert {:ok, _} = Chat.toggle_reaction(root.id, "+1", @maggie)
    assert {:ok, _} = Chat.toggle_reaction(reply.id, "seen", @maggie)
    {before_restart, _server} = player(@you, room_id)
    before_restart = Assembly.action(:open_thread, %{message_id: root.id}, before_restart)

    assert {:ok, path} = ChatStorage.path()
    assert File.regular?(path)
    previous_pid = Process.whereis(ChatStorage)
    assert :ok = Supervisor.terminate_child(Jido.Assembly.Supervisor, ChatStorage)
    assert {:ok, new_pid} = Supervisor.restart_child(Jido.Assembly.Supervisor, ChatStorage)
    assert previous_pid != new_pid
    assert {:ok, ^path} = ChatStorage.path()

    {after_restart, _server} = player(@you, room_id)
    after_restart = Assembly.action(:open_thread, %{message_id: root.id}, after_restart)
    assert after_restart.state.thread_root.reactions == before_restart.state.thread_root.reactions

    assert [%{emoji: "+1", count: 2, reacted: true, user_ids: actors}] =
             after_restart.state.thread_root.reactions

    assert Enum.sort(actors) == [@maggie, @you]
    assert after_restart.state.thread_messages == before_restart.state.thread_messages

    assert [%{reactions: [%{emoji: "seen", count: 1, user_ids: [@maggie], reacted: false}]}] =
             after_restart.state.thread_messages
  end

  test "the bounded agent round passes earlier contributions to later agents in order" do
    room_id = room!()
    request = post!(room_id, "Check impact, delivery, and next steps.")
    parent = self()

    responder = fn agent, _room, transcript ->
      send(parent, {:agent_context, agent.id, Enum.map(transcript, & &1.sender_id)})
      {:ok, "Evidence from #{agent.name}."}
    end

    assert {:ok, result} =
             Agents.run_round(room_id,
               prompt_message_id: request.id,
               responder: responder,
               inter_agent_enabled: true
             )

    assert_receive {:agent_context, @triage, [@you]}
    assert_receive {:agent_context, @bridge, [@you, @triage]}
    assert_receive {:agent_context, @runbook, [@you, @triage, @bridge]}
    assert Enum.map(result.messages, & &1.sender_id) == [@triage, @bridge, @runbook]
    assert Enum.all?(result.messages, &(&1.metadata["agent_prompt_message_id"] == request.id))
  end

  @tag scenario: "AT01"
  test "a player starts one durable Triage run from the normal channel composer" do
    room_id = room!()
    {page, server} = player(@you, room_id)
    body = "@triage check this release request."
    command = Assembly.action(:send_message, %{"body" => body}, page).next_command

    %{message: %{id: request_id, sender_id: @you}} =
      broadcast!(command.name, command.params, server)

    assert {:ok,
            [%{id: run_id, trigger_id: ^request_id, thread_id: ^request_id, status: "queued"}]} =
             ChatStorage.list_agent_runs(room_id)

    assert {:ok, path} = ChatStorage.path()

    reopened =
      start_supervised!({ChatStorage, id: :run_reader, name: __MODULE__.RunReader, path: path})

    assert {:ok, [%{id: ^run_id, trigger_id: ^request_id, status: "queued"}]} =
             ChatStorage.list_agent_runs(reopened, room_id)

    start_scripted_inference!(["Check the deploy receipt."])
    assert [%{id: ^run_id, status: "completed"}] = await_agent_runs!(room_id)
    assert [_call] = ScriptedInference.calls()
  end

  @tag scenario: "AT02"
  test "a Jido Triage turn saves its assistant answer in the exact request thread" do
    room_id = room!()
    request_id = post!(room_id, "@triage check the release.").id
    answer = "Review the provider receipts before publishing."
    start_scripted_inference!([answer])

    assert [%{id: run_id, trigger_id: ^request_id, status: "completed", reply: ^answer}] =
             await_agent_runs!(room_id)

    assert [_call] = ScriptedInference.calls()
    reply_id = run_id <> ":reply"

    supervisor = Jido.Assembly.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, record} = ChatRuntime.get_room_history(room_id, reply_id)

    assert %{
             id: ^reply_id,
             role: :assistant,
             sender_id: @triage,
             thread_id: ^request_id,
             reply_to_id: ^request_id,
             metadata: %{"agent_run_id" => ^run_id, "agent_prompt_message_id" => ^request_id}
           } = Chat.message_record(record)

    {peer, _server} = player(@maggie, room_id)
    peer = Assembly.action(:open_thread, %{message_id: request_id}, peer)
    assert [%{id: ^reply_id, body: ^answer, sender_id: @triage}] = peer.state.thread_messages
    refute timeline_message(peer, reply_id)
  end

  @tag scenario: "AT03"
  test "a mention in a human reply runs Triage under the original root and exact parent" do
    room_id = room!()
    root_id = post!(room_id, "Release checkpoint").id
    sibling_id = post!(room_id, "Can someone check the signatures?", @you, thread_id: root_id).id
    {peer, server} = player(@maggie, room_id)
    peer = Assembly.action(:open_thread, %{message_id: root_id}, peer)
    body = "@triage check the provider receipts."
    command = Assembly.action(:send_reply, %{"reply" => body}, peer).next_command

    %{message: %{id: request_id, thread_id: ^root_id, sender_id: @maggie}} =
      broadcast!(command.name, command.params, server)

    answer = "The callback receipt still needs review."
    start_scripted_inference!([answer])

    assert [%{id: run_id, trigger_id: ^request_id, thread_id: ^root_id, status: "completed"}] =
             await_agent_runs!(room_id)

    reply_id = run_id <> ":reply"

    assert [
             %{id: ^sibling_id},
             %{id: ^request_id, reply_to_id: ^root_id},
             %{id: ^reply_id, reply_to_id: ^request_id, sender_id: @triage, body: ^answer}
           ] = Chat.list_thread_views(room_id, root_id, @you)

    assert [%{id: ^root_id}] =
             Enum.reject(
               Chat.list_message_views(room_id, @you),
               &(&1.metadata["role"] == "system")
             )
  end

  @tag scenario: "AT04"
  test "Triage receives the selected request and its replies without sibling or other room content" do
    room_id = room!()
    request = post!(room_id, "@triage check release status.")
    sibling = post!(room_id, "Unrelated support case.")
    in_scope = post!(room_id, "CI passed.", @maggie, thread_id: request.id)
    out_of_scope = post!(room_id, "Unrelated support evidence.", @maggie, thread_id: sibling.id)
    elsewhere = post!(room!(), "Separate room evidence.")

    start_scripted_inference!(["CI passed. Check the provider receipts next."])
    assert [%{status: "completed"}] = await_agent_runs!(room_id)
    assert [%{messages: messages}] = ScriptedInference.calls()
    context = for %{content: parts} <- messages, %{type: :text, text: text} <- parts, do: text
    transcript = Enum.join(context, "\n")

    assert transcript =~ "Triggering request from #{request.author}: #{request.body}"
    assert transcript =~ in_scope.body
    refute transcript =~ sibling.body
    refute transcript =~ out_of_scope.body
    refute transcript =~ elsewhere.body
  end

  @tag scenario: "AT05"
  test "agent entry points reject an anchor from another room before calling the model" do
    room_id = room!()
    post!(room_id, "Evidence in the selected room.")
    other = room!()
    request = post!(other, "Request in a different room.")
    start_supervised!({ScriptedInference, ["This response must remain unused."]})
    opts = [inference_client: ScriptedInference, max_agents: 1, prompt_message_id: request.id]

    assert {:error, :trigger_unavailable} = Agents.run_round(room_id, opts)
    assert {:error, :trigger_unavailable} = Agents.reply_to_trigger(room_id, request.id, opts)
    assert [] = ScriptedInference.calls()

    for id <- [room_id, other] do
      assert {:ok, []} = ChatStorage.list_agent_runs(id)
      assert {:ok, history} = ChatRuntime.list_room_history(id)
      refute Enum.any?(history, &(Chat.message_record(&1).role == :assistant))
    end
  end

  @tag scenario: "AT06"
  test "plain messages and code literals do not start a Triage run" do
    room_id = room!()

    ignored =
      for body <- [
            "Please check the release.",
            "Use `@triage` in the example.",
            "Example:\n```text\n@triage review the release\n```"
          ] do
        post!(room_id, body)
      end

    assert Enum.all?(ignored, &(&1.mentioned_user_ids == []))
    assert {:ok, []} = ChatStorage.list_agent_runs(room_id)

    request_id = post!(room_id, "@triage check the release.").id
    start_scripted_inference!(["Check the deployment receipt."])
    assert [%{trigger_id: ^request_id, status: "completed"}] = await_agent_runs!(room_id)
    assert [_call] = ScriptedInference.calls()
    assert Enum.all?(ignored, &(Chat.list_thread_views(room_id, &1.id, @you) == []))
  end

  @tag scenario: "AT07"
  test "replaying the same committed request keeps one run, one reply, and the original IDs" do
    room_id = room!()
    body = "@triage review the replayed request."
    request = post!(room_id, body)
    request_id = request.id

    assert {:ok, [%{id: run_id, trigger_id: ^request_id, status: "queued"}]} =
             ChatStorage.list_agent_runs(room_id)

    assert %{id: ^request_id} = post!(room_id, body, @you, message_id: request_id)
    start_scripted_inference!(["Check the provider test output."])

    assert [%{id: ^run_id, trigger_id: ^request_id, status: "completed"}] =
             await_agent_runs!(room_id)

    assert %{id: ^request_id} = post!(room_id, body, @you, message_id: request_id)

    assert {:ok, [%{id: ^run_id, trigger_id: ^request_id, status: "completed"}]} =
             ChatStorage.list_agent_runs(room_id)

    assert [_call] = ScriptedInference.calls()

    assert [%{id: ^request_id}] =
             Enum.filter(Chat.list_message_views(room_id, @you), &(&1.body == body))

    reply_id = run_id <> ":reply"

    assert [%{id: ^reply_id, reply_to_id: ^request_id}] =
             Chat.list_thread_views(room_id, request_id, @you)
  end

  @tag scenario: "AT08"
  test "two independent posts with identical text produce separate Triage runs" do
    room_id = room!()
    body = "@triage check the run correlation."
    first_id = post!(room_id, body).id
    second_id = post!(room_id, body).id
    assert first_id != second_id

    answers = ["Check the package build.", "Check the delivery receipt."]
    start_scripted_inference!(answers)

    assert [
             %{id: first_run, trigger_id: ^first_id, status: "completed"},
             %{id: second_run, trigger_id: ^second_id, status: "completed"}
           ] = await_agent_runs!(room_id)

    assert first_run != second_run
    assert [_first, _second] = ScriptedInference.calls()

    assert [
             %{
               reply_to_id: ^first_id,
               body: first_answer,
               metadata: %{"agent_run_id" => ^first_run}
             }
           ] =
             Chat.list_thread_views(room_id, first_id, @maggie)

    assert [
             %{
               reply_to_id: ^second_id,
               body: second_answer,
               metadata: %{"agent_run_id" => ^second_run}
             }
           ] =
             Chat.list_thread_views(room_id, second_id, @maggie)

    assert Enum.sort([first_answer, second_answer]) == Enum.sort(answers)
  end

  @tag scenario: "AT10"
  test "registered mention case variants resolve once and unknown aliases do not start a run" do
    room_id = room!()
    unknown = post!(room_id, "Ask @triage-preview to check the package.")
    assert unknown.mentioned_user_ids == []
    assert {:ok, []} = ChatStorage.list_agent_runs(room_id)

    request = post!(room_id, "Ask @TrIaGe and @TRIAGE to check this one request.")
    assert request.mentioned_user_ids == [@triage]
    assert request.metadata["mention_handles"] == ["triage"]
    request_id = request.id

    start_scripted_inference!(["Review the fixture receipt."])
    assert [%{trigger_id: ^request_id, status: "completed"}] = await_agent_runs!(room_id)
    assert [_call] = ScriptedInference.calls()
    assert [%{sender_id: @triage}] = Chat.list_thread_views(room_id, request_id, @you)
    assert [] = Chat.list_thread_views(room_id, unknown.id, @you)
  end

  @tag scenario: "AT11"
  test "a private room without Triage membership keeps its messages out of agent inference" do
    private = "dm:maggie"
    room_id = room!()
    secret = "@triage Check the private review details for this request."
    request = post!(private, secret)
    assert request.mentioned_user_ids == [@triage]
    assert {:ok, nil} = ChatRuntime.get_room_membership(private, @triage)
    assert {:ok, []} = ChatStorage.list_agent_runs(private)

    explicit =
      post!(room_id, "@triage Check this manual prompt.", @you, metadata: %{agent_prompt: true})

    assert {:ok, []} = ChatStorage.list_agent_runs(room_id)

    start_scripted_inference!(["Check the public release receipt."])
    opts = [inference_client: ScriptedInference, max_agents: 1, prompt_message_id: request.id]
    assert {:error, :agent_room_forbidden} = Agents.run_round(private, opts)
    assert {:error, :trigger_unavailable} = Agents.reply_to_trigger(private, request.id, opts)
    assert [] = ScriptedInference.calls()

    public_id = post!(room_id, "@triage check the public release.").id
    assert [%{trigger_id: ^public_id, status: "completed"}] = await_agent_runs!(room_id)
    assert [%{messages: messages}] = ScriptedInference.calls()
    context = for %{content: parts} <- messages, %{type: :text, text: text} <- parts, do: text
    refute Enum.any?(context, &String.contains?(&1, secret))
    assert {:ok, []} = ChatStorage.list_agent_runs(private)
    assert [] = Chat.list_thread_views(private, request.id, @you)
    assert [] = Chat.list_thread_views(room_id, explicit.id, @you)
  end

  @tag scenario: "AT12"
  test "a long thread keeps its original trigger and recent human evidence within the budget" do
    room_id = room!()
    root = post!(room_id, "Release checkpoint.")
    trigger = post!(room_id, "@triage check the release notes.", @you, thread_id: root.id)

    for index <- 1..12 do
      post!(room_id, "Old evidence number #{index}.", @maggie, thread_id: root.id)
    end

    evidence = post!(room_id, "Package CI passed.", @maggie, thread_id: root.id)
    long = "Delivery receipt: " <> String.duplicate("é", 50) <> " End of note."
    post!(room_id, long, @maggie, thread_id: root.id)
    post!(room_id, "Old assistant result.", @triage, thread_id: root.id, role: :assistant)
    elsewhere = post!(room!(), "Other room private evidence.")

    start_scripted_inference!(["Review the newest receipt."],
      context_message_limit: 4,
      context_bytes_per_message: 65
    )

    assert [%{status: "completed"}] = await_agent_runs!(room_id)
    assert [%{messages: messages}] = ScriptedInference.calls()
    context = for %{content: parts} <- messages, %{type: :text, text: text} <- parts, do: text
    prompt = Enum.join(context, "\n")
    refute prompt =~ "Old evidence number"
    refute prompt =~ "Old assistant result."
    refute prompt =~ "End of note."
    refute prompt =~ elsewhere.body

    assert [_, transcript] = String.split(prompt, "Transcript:\n", parts: 2)
    assert [lines, _] = String.split(transcript, "\n\n", parts: 2)

    root_line = "#{root.author}: #{root.body}"
    trigger_line = "Triggering request from #{trigger.author}: #{trigger.body}"
    evidence_line = "#{evidence.author}: #{evidence.body}"

    assert [^root_line, ^trigger_line, ^evidence_line, "Maggie: " <> shortened] =
             String.split(lines, "\n", trim: true)

    assert shortened == "Delivery receipt: " <> String.duplicate("é", 23)
    assert byte_size(shortened) <= 65
    assert String.valid?(shortened)
  end

  @tag :assembly_target
  test "retry after a partial agent round preserves the committed finding" do
    room_id = room!()
    request = post!(room_id, "Check impact, delivery, and next steps.")
    opts = [prompt_message_id: request.id]

    fail_bridge = fn
      %{id: @bridge}, _room, _transcript -> {:error, :fixture_unavailable}
      agent, room, transcript -> answer(agent, room, transcript)
    end

    assert {:error, {:agent_failed, _, :fixture_unavailable}} =
             Agents.run_round(room_id, Keyword.put(opts, :responder, fail_bridge))

    assert [%{id: finding_id, sender_id: @triage}] = agent_findings(room_id, request.id)

    parent = self()

    retry = fn agent, room, transcript ->
      send(parent, {:retried_agent, agent.id})
      answer(agent, room, transcript)
    end

    assert {:ok, _} = Agents.run_round(room_id, Keyword.put(opts, :responder, retry))
    refute_received {:retried_agent, @triage}
    assert_received {:retried_agent, @bridge}
    assert_received {:retried_agent, @runbook}

    assert [
             %{id: ^finding_id, sender_id: @triage},
             %{sender_id: @bridge},
             %{sender_id: @runbook}
           ] = agent_findings(room_id, request.id)
  end

  defp room! do
    name = "multiplayer-#{System.unique_integer([:positive])}"
    assert {:ok, room, _messages, _signals} = Chat.create_channel_command(%{name: name})
    room.id
  end

  defp player(user, room_id) do
    {page, server} =
      init_page(Assembly, %{},
        session_id: "multiplayer-#{user}",
        instance_id: user,
        user_id: user
      )

    page = Assembly.action(:snapshot_loaded, %{snapshot: Chat.snapshot(user, room_id)}, page)
    {%{page | next_command: nil}, server}
  end

  defp open_link(url, user) do
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    init_page(Assembly, %{}, query: query, user_id: user)
  end

  defp post!(room_id, body, sender \\ @you, opts \\ []) do
    assert {:ok, message} = Chat.send_message(room_id, body, sender, opts)
    message
  end

  defp start_scripted_inference!(replies, opts \\ []) do
    start_supervised!({ScriptedInference, replies})
    previous = Application.fetch_env!(:jido_assembly, :agent_trigger_options)
    on_exit(fn -> Application.put_env(:jido_assembly, :agent_trigger_options, previous) end)

    Application.put_env(
      :jido_assembly,
      :agent_trigger_options,
      Keyword.put(opts, :inference_client, ScriptedInference)
    )
  end

  defp await_agent_runs!(room_id) do
    await_agent_runs!(room_id, System.monotonic_time(:millisecond) + 3_000)
  end

  defp await_agent_runs!(room_id, deadline) do
    assert {:ok, runs} = ChatStorage.list_agent_runs(room_id)

    if runs != [] and Enum.all?(runs, &(&1.status in ["completed", "failed"])) do
      runs
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "Agent runs stalled: #{inspect(runs)}"

      receive do
      after
        20 -> await_agent_runs!(room_id, deadline)
      end
    end
  end

  defp broadcast!(name, params, server) do
    assert [%Broadcast{action_name: :message_saved, params: saved}] =
             Assembly.command(name, params, server).broadcasts

    saved
  end

  defp react!(page, server, message_id, emoji, active? \\ true) do
    command = reaction_command(page, message_id, emoji, active?)

    assert [%Broadcast{action_name: :reaction_saved, params: saved}] =
             Assembly.command(command.name, command.params, server).broadcasts

    saved
  end

  defp reaction_command(page, message_id, emoji, active?) do
    Assembly.action(:set_reaction, %{message_id: message_id, emoji: emoji, active: active?}, page).next_command
  end

  defp timeline_message(page, id), do: Enum.find(page.state.messages, &(&1.id == id))

  defp room_view(page, id), do: Enum.find(page.state.rooms, &(&1.id == id))

  defp apply_posts(page, posts) do
    Enum.reduce(posts, page, &Assembly.action(:message_saved, &1, &2))
  end

  defp refute_new_message_event(room_id, last_sequence) do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:signal,
              %Jido.Signal{
                data: %{"room" => %Jido.Agent.Address{id: ^room_id}, "sequence" => sequence}
              }} ->
               sequence > last_sequence

             _other ->
               false
           end)
  end

  defp agent_findings(room_id, request_id) do
    assert {:ok, history} = ChatRuntime.list_room_history(room_id, limit: 30)

    history
    |> Enum.map(&Chat.message_record/1)
    |> Enum.filter(&(&1.metadata["agent_prompt_message_id"] == request_id))
  end

  defp answer(_agent, _room, _transcript), do: {:ok, "Release evidence checked."}
end
