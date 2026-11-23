defmodule Jido.AssemblyWeb.ReleaseNotesControllerTest do
  use Jido.AssemblyWeb.ConnCase, async: false

  alias Jido.Assembly.{Chat, ChatRuntime, ChatStorage, ReleaseNotes, Seeds}
  alias Jido.Assembly.ReleaseNotes.Workflow

  @tag scenario: "HF01"
  test "Triage saves Maya's decision with both choices after a restart", %{conn: conn} do
    supervisor = Jido.Assembly.Supervisor
    room_id = Seeds.release_room_id()
    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(supervisor, Workflow) end)

    {_conn, url} =
      submit(conn, %{
        "as" => "maya",
        "operation" => "request",
        "body" => "@triage ask me which release checks to require."
      })

    assert "decision-" <> root_id = decision_id = URI.parse(url).fragment
    assert {:ok, [^root_id]} = ChatStorage.ready_release_steps()
    assert {:ok, nil} = ChatRuntime.get_room_history(room_id, decision_id)

    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, [^root_id]} = ChatStorage.ready_release_steps()
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)

    record = await_history!(room_id, decision_id, System.monotonic_time(:millisecond) + 3_000)

    choices = %{
      "document" => "Document the pending checks",
      "hold" => "Wait for full live coverage"
    }

    assert %{
             id: ^decision_id,
             role: :assistant,
             sender_id: "agent:triage",
             thread_id: ^root_id,
             reply_to_id: ^root_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "decision",
                 "run_id" => ^root_id,
                 "assignee" => "maya",
                 "choices" => ^choices
               }
             }
           } = Chat.message_record(record)

    assert {:ok, []} = ChatStorage.ready_release_steps()
    assert {:ok, %{id: ^decision_id}} = Workflow.advance(root_id)
    assert [%{id: ^decision_id}] = Chat.list_thread_views(room_id, root_id)

    assert %{status: :decision, allowed_choices: ^choices, target: ^decision_id} =
             pending_run(root_id, "maya")

    page = visit(conn, url) |> html_response(200)
    assert page =~ ~s(id="#{decision_id}")
    assert page =~ ~s(value="document")
    assert page =~ ~s(value="hold")

    assert {:ok, draft} =
             ReleaseNotes.submit(
               "maya",
               action("maya", "decide", root_id, decision_id, %{"choice" => "document"})
             )

    assert {:ok, _review} =
             ReleaseNotes.submit(
               "eli",
               action("eli", "review", root_id, ReleaseNotes.message_anchor(draft.id))
             )
  end

  @tag scenario: "HF02"
  test "Needs you links Maya to the stored decision and omits it for Eli", %{conn: conn} do
    root = request!("maya", "@triage choose the release criteria from Needs you.")
    decision_id = ReleaseNotes.decision_anchor(root.id)
    expected_url = "/release-notes?as=maya##{decision_id}"

    maya = dom(conn, "/release-notes?as=maya&view=inbox")
    eli = dom(conn, "/release-notes?as=eli&view=inbox")
    assert [^expected_url] = maya |> LazyHTML.query(".release-item") |> LazyHTML.attribute("href")
    assert [] = eli |> LazyHTML.query(".release-item") |> LazyHTML.attribute("href")

    page = dom(conn, expected_url)
    decision = LazyHTML.query_by_id(page, decision_id)

    assert [root.id] ==
             decision |> LazyHTML.query(~s(input[name="root"])) |> LazyHTML.attribute("value")

    assert [decision_id] ==
             decision |> LazyHTML.query(~s(input[name="target"])) |> LazyHTML.attribute("value")

    assert LazyHTML.text(LazyHTML.query_by_id(page, ReleaseNotes.message_anchor(root.id))) =~
             root.body

    assert {:ok, %{thread_id: thread_id}} =
             ChatRuntime.get_room_history(Seeds.release_room_id(), decision_id)

    assert thread_id == root.id

    draft = decide!(root.id, "maya")
    review!(root.id, "eli", draft.id)
  end

  @tag scenarios: ~w(HF02 HF03 HF04 HF06 HF07 HF08)
  test "Maya starts a thread, Eli revises the draft, and Maya reviews the new version", %{
    conn: conn
  } do
    conn = get(conn, "/release-notes")
    assert html_response(conn, 200) =~ "Send to Triage"

    {conn, decision_url} =
      submit(conn, %{
        "as" => "maya",
        "operation" => "request",
        "body" => "@triage Make the Jido Chat release note."
      })

    decision = URI.parse(decision_url).fragment
    assert "decision-" <> root_id = decision
    assert %{status: :decision, target: ^decision} = pending_run(root_id, "maya")

    conn = visit(conn, "/release-notes?as=maya&view=inbox")
    assert html_response(conn, 200) =~ ~s(href="#{decision_url}")

    conn = visit(conn, decision_url)
    decision_page = html_response(conn, 200)
    assert decision_page =~ ~s(id="#{decision}")
    assert decision_page =~ "Maya Reyes"
    assert decision_page =~ "Document the pending checks"

    {conn, rejected_url} =
      submit(conn, action("eli", "decide", root_id, decision, %{"choice" => "document"}))

    conn = visit(conn, rejected_url)
    assert html_response(conn, 200) =~ "belongs to another reviewer"

    {conn, draft_url} =
      submit(conn, action("maya", "decide", root_id, decision, %{"choice" => "document"}))

    draft_target = URI.parse(draft_url).fragment

    conn = visit(conn, "/release-notes?as=eli&view=inbox")
    assert html_response(conn, 200) =~ ~s(href="/release-notes?as=eli##{draft_target}")

    conn = visit(conn, "/release-notes?as=maya&view=board")
    assert html_response(conn, 200) =~ ~s(href="#{draft_url}")

    conn = visit(conn, "/release-notes?as=eli##{draft_target}")
    draft_page = html_response(conn, 200)
    assert draft_page =~ ~s(id="#{draft_target}")
    assert draft_page =~ "Release note · v1"
    assert draft_page =~ "Triage Agent"
    assert draft_page =~ "Suggest edit"
    assert draft_page =~ "Live provider matrix"

    revision = "Package CI passed. Discord, Slack, Signal, and X still need live verification."

    {conn, revision_url} =
      submit(conn, action("eli", "revise", root_id, draft_target, %{"body" => revision}))

    revision_target = URI.parse(revision_url).fragment

    {conn, stale_url} = submit(conn, action("eli", "review", root_id, draft_target))
    conn = visit(conn, stale_url)
    assert html_response(conn, 200) =~ "belongs to another reviewer"

    conn = visit(conn, "/release-notes?as=maya&view=inbox")
    assert html_response(conn, 200) =~ ~s(href="/release-notes?as=maya##{revision_target}")

    conn = visit(conn, "/release-notes?as=maya##{revision_target}")
    revision_page = html_response(conn, 200)
    assert revision_page =~ ~s(id="#{revision_target}")
    assert revision_page =~ "Release note · v1"
    assert revision_page =~ "Release note · v2"
    assert revision_page =~ revision
    assert revision_page =~ "Eli Park"

    assert "message-" <> revision_id = revision_target

    assert {:ok, %{reactions: [%{emoji: "ship", count: 1}]}} =
             Chat.toggle_reaction(revision_id, "ship", "user:maya")

    conn = visit(conn, "/release-notes?as=maya&view=inbox")
    assert html_response(conn, 200) =~ ~s(href="/release-notes?as=maya##{revision_target}")

    {conn, review_url} = submit(conn, action("maya", "review", root_id, revision_target))
    conn = visit(conn, review_url)
    assert html_response(conn, 200) =~ "Marked release note v2 reviewed."

    conn = visit(conn, "/release-notes?as=maya&view=inbox")
    assert html_response(conn, 200) =~ "You have no pending decisions or reviews."

    conn = visit(conn, "/release-notes?as=eli&view=board")
    assert html_response(conn, 200) =~ ~s(href="/release-notes?as=eli##{revision_target}")

    [decision_message, answer, draft, revised, review] =
      Chat.list_thread_views(Seeds.release_room_id(), root_id)

    assert decision_message.id == decision
    assert answer.sender_id == "user:maya"
    assert answer.reply_to_id == decision
    assert draft.sender_id == "agent:triage"
    assert draft.reply_to_id == answer.id
    assert revised.sender_id == "user:eli"
    assert revised.reply_to_id == draft.id
    assert review.sender_id == "user:maya"
    assert review.reply_to_id == revised.id
  end

  @tag scenario: "HF04"
  test "the reference route uses Eli's signed session for both links and submitted choices", %{
    conn: conn
  } do
    root = request!("maya", "@triage start Maya's decision with a signed reviewer session.")
    room = Seeds.release_room_id()
    decision = ReleaseNotes.decision_anchor(root.id)
    authenticated = Plug.Test.init_test_session(conn, %{hologram_user_id: "user:eli"})

    page =
      authenticated
      |> get("/release-notes?as=maya")
      |> html_response(200)
      |> LazyHTML.from_document()

    card = LazyHTML.query_by_id(page, decision)
    assert LazyHTML.text(card) =~ "Maya Reyes"
    assert card |> LazyHTML.query("form") |> LazyHTML.to_tree() == []
    assert page |> LazyHTML.query(~s(nav[aria-label="View as"])) |> LazyHTML.to_tree() == []
    assert {:ok, before} = ChatRuntime.list_room_history(room, thread_id: root.id)

    response =
      post(
        authenticated,
        "/release-notes",
        action("maya", "decide", root.id, decision, %{"choice" => "hold"})
      )

    assert redirected_to(response, 303) == "/release-notes?as=eli##{decision}"
    assert {:ok, ^before} = ChatRuntime.list_room_history(room, thread_id: root.id)
    assert %{status: :decision, assignee: "maya"} = pending_run(root.id, "maya")

    draft = decide!(root.id, "maya")
    review!(root.id, "eli", draft.id)
  end

  @tag scenario: "EM12"
  test "reactions leave release decisions and artifact reviews pending", %{conn: conn} do
    room_id = Seeds.release_room_id()

    assert {:ok, request} =
             ReleaseNotes.submit("maya", %{
               "operation" => "request",
               "body" => "@triage Draft a note for the reaction acceptance test."
             })

    decision = "decision-" <> request.id
    assert {:ok, history} = ChatRuntime.list_room_history(room_id)

    for emoji <- ["ship", "✅", "+1"] do
      assert {:ok, _, _} = Chat.set_reaction_command(request.id, emoji, "user:maya", true)
    end

    assert {:ok, ^history} = ChatRuntime.list_room_history(room_id)
    assert %{status: :decision, target: ^decision, changes: []} = pending_run(request.id, "maya")

    assert {:ok, draft} =
             ReleaseNotes.submit(
               "maya",
               action("maya", "decide", request.id, decision, %{"choice" => "document"})
             )

    draft_target = ReleaseNotes.message_anchor(draft.id)
    assert {:ok, history} = ChatRuntime.list_room_history(room_id)

    for emoji <- ["ship", "✅", "+1"] do
      assert {:ok, _, _} = Chat.set_reaction_command(draft.id, emoji, "user:eli", true)
    end

    assert {:ok, ^history} = ChatRuntime.list_room_history(room_id)

    assert %{status: :review, target: ^draft_target, changes: [change]} =
             pending_run(request.id, "eli")

    assert change.id == draft.id

    inbox = visit(conn, "/release-notes?as=eli&view=inbox")
    assert html_response(inbox, 200) =~ ~s(href="/release-notes?as=eli##{draft_target}")

    assert {:ok, _} =
             ReleaseNotes.submit("eli", action("eli", "review", request.id, draft_target))
  end

  defp pending_run(id, assignee) do
    assignee
    |> ReleaseNotes.runs()
    |> ReleaseNotes.inbox(assignee)
    |> Enum.find(&(&1.id == id))
  end

  defp request!(person, body) do
    assert {:ok, root} = ReleaseNotes.submit(person, %{"operation" => "request", "body" => body})
    root
  end

  defp decide!(root, person, choice \\ "document") do
    assert {:ok, draft} =
             ReleaseNotes.submit(
               person,
               action(person, "decide", root, ReleaseNotes.decision_anchor(root), %{
                 "choice" => choice
               })
             )

    draft
  end

  defp review!(root, person, message_id) do
    assert {:ok, review} =
             ReleaseNotes.submit(
               person,
               action(person, "review", root, ReleaseNotes.message_anchor(message_id))
             )

    review
  end

  defp dom(conn, path), do: conn |> visit(path) |> html_response(200) |> LazyHTML.from_document()

  defp await_history!(room, id, deadline) do
    case ChatRuntime.get_room_history(room, id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{} = record} ->
        record

      {:ok, nil} ->
        assert System.monotonic_time(:millisecond) < deadline, "Message #{id} did not commit"

        receive do
        after
          10 -> await_history!(room, id, deadline)
        end
    end
  end

  defp action(person, operation, root, target, extra \\ %{}) do
    Map.merge(
      %{"as" => person, "operation" => operation, "root" => root, "target" => target},
      extra
    )
  end

  defp submit(conn, params) do
    conn = conn |> recycle() |> post("/release-notes", params)
    {conn, redirected_to(conn, 303)}
  end

  defp visit(conn, url) do
    uri = URI.parse(url)
    path = if uri.query, do: uri.path <> "?" <> uri.query, else: uri.path
    conn |> recycle() |> get(path)
  end
end
