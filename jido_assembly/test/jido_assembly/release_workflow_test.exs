defmodule Jido.Assembly.ReleaseWorkflowTest do
  use Jido.Assembly.HologramPageCase, async: false

  alias Hologram.Server.Broadcast
  alias Hologram.Template.Renderer
  alias Hologram.Template.Renderer.Env
  alias Jido.Assembly.{Chat, ChatRuntime, ChatStorage, ReleaseNotes, Seeds}
  alias Jido.Assembly.Components.Assembly.{ReleaseWork, Sidebar, ThreadPanel}
  alias Jido.Assembly.Pages.Assembly
  alias Jido.Assembly.ReleaseNotes.Workflow
  alias Jido.AssemblyWeb.RuntimeNotifier

  @maya "user:maya"
  @eli "user:eli"

  @tag scenario: "HF01"
  test "Maya starts the durable decision from the main channel composer" do
    room = Seeds.release_room_id()
    {page, server} = player(@maya, room)
    body = "@triage ask me which release checks to require."
    command = Assembly.action(:send_message, %{"body" => body}, page).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: request}}] =
             Assembly.command(command.name, command.params, server).broadcasts

    assert %{body: ^body, sender_id: @maya} = request
    root_id = request.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    assert {:ok, %{thread_id: ^root_id}} = ChatRuntime.get_room_history(room, decision_id)

    {opened, server} = player(@maya, room, decision_id)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^decision_id} = opened.state
    assert [%{id: ^decision_id, reply_to_id: ^root_id}] = opened.state.thread_messages

    document = thread_dom(opened, server)

    text =
      document
      |> LazyHTML.query(~s([data-assembly-message-id="#{decision_id}"]))
      |> LazyHTML.text()

    assert text =~ "Triage Agent"
    assert text =~ "Assigned to Maya Reyes"
    assert text =~ "Document the pending checks"
    assert text =~ "Wait for full live coverage"

    finish!(root_id)
  end

  @tag scenario: "HF02"
  test "the main chat Needs you view refreshes for Maya and opens the exact decision" do
    room = Seeds.release_room_id()
    {maya, maya_server} = player(@maya, room)
    {eli, eli_server} = player(@eli, room)
    assert maya.state.release_work.inbox == []
    assert eli.state.release_work.inbox == []

    root = request!("@triage choose the required release checks.")

    root_id = root.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    assert {:ok, record} = ChatRuntime.get_room_history(room, decision_id)
    assert {:ok, event} = RuntimeNotifier.message_saved_params(record.signal)
    maya = apply_work_event(maya, maya_server, event)
    eli = apply_work_event(eli, eli_server, event)

    assert [%{run_id: ^root_id, message_id: ^decision_id, href: href}] =
             maya.state.release_work.inbox

    assert [] = eli.state.release_work.inbox

    maya_dom = release_view(maya, maya_server, "inbox")
    eli_dom = release_view(eli, eli_server, "inbox")
    target_link = ~s([aria-label="Assignments"] [data-assembly-release-target="#{decision_id}"])
    assert [^href] = maya_dom |> LazyHTML.query(target_link) |> LazyHTML.attribute("href")
    assert [] = eli_dom |> LazyHTML.query(target_link) |> LazyHTML.attribute("href")

    {opened, _server} = open_link(@maya, href)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^decision_id} = opened.state

    finish!(root_id)
  end

  @tag scenario: "HF03"
  test "the main Board opens the pending decision, then retargets the same request to v1" do
    room = Seeds.release_room_id()
    root = request!("@triage prepare the release criteria for the Board.")
    root_id = root.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    {eli, eli_server} = player(@eli, room)

    decision_selector =
      ~s([aria-label="Release board"] [data-assembly-release-lane="decision"] [data-assembly-release-target="#{decision_id}"])

    assert [decision_link] =
             eli
             |> release_view(eli_server, "board")
             |> LazyHTML.query(decision_selector)
             |> LazyHTML.attribute("href")

    {opened, _server} = open_link(@eli, decision_link)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^decision_id} = opened.state

    draft = decide!(root_id)
    draft_id = draft.id
    assert {:ok, record} = ChatRuntime.get_room_history(room, draft_id)
    assert {:ok, event} = RuntimeNotifier.message_saved_params(record.signal)
    eli = apply_work_event(eli, eli_server, event)
    board = release_view(eli, eli_server, "board")
    assert [] = board |> LazyHTML.query(decision_selector) |> LazyHTML.attribute("href")

    draft_selector =
      ~s([aria-label="Release board"] [data-assembly-release-lane="review"] [data-assembly-release-target="#{draft_id}"])

    assert [draft_link] = board |> LazyHTML.query(draft_selector) |> LazyHTML.attribute("href")

    assert [%{run_id: ^root_id, message_id: ^draft_id, href: ^draft_link}] =
             eli.state.release_work.inbox

    {opened, _server} = open_link(@eli, draft_link)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^draft_id} = opened.state
    assert %{id: ^draft_id} = Enum.find(opened.state.thread_messages, &(&1.id == draft_id))

    review!(root_id, draft_id)
  end

  @tag scenario: "HF04"
  test "Eli cannot answer Maya's decision through her exact main chat link or a forged command" do
    root = request!("@triage prepare a decision for Maya only.")
    room = Seeds.release_room_id()
    root_id = root.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    {maya, _server} = player(@maya, room)
    assert [%{href: href}] = maya.state.release_work.inbox
    {owner, owner_server} = open_link(@maya, href)
    {eli, eli_server} = open_link(@eli, href)
    assert eli.state.thread_root.id == root_id
    assert eli.state.focused_message_id == decision_id
    assert eli.state.current_user.id == @eli

    selector = ~s(section[aria-label="Release decision"] button)

    assert owner |> thread_dom(owner_server) |> LazyHTML.query(selector) |> LazyHTML.text() =~
             "Document the pending checks"

    assert eli |> thread_dom(eli_server) |> LazyHTML.query(selector) |> LazyHTML.to_tree() == []

    assert {:ok, before} = ChatRuntime.list_room_history(room, thread_id: root_id)

    command =
      Assembly.action(:answer_release_decision, %{target: decision_id, choice: "hold"}, eli).next_command

    spoofed = Map.merge(command.params, %{sender_id: @maya, person: "maya"})
    rejected = Assembly.command(command.name, spoofed, eli_server)
    assert %{name: :release_action_failed, params: %{error: error}} = rejected.next_action
    assert error =~ "belongs to another reviewer"
    assert rejected.broadcasts == []
    assert {:ok, ^before} = ChatRuntime.list_room_history(room, thread_id: root_id)
    assert [%{run_id: ^root_id, message_id: ^decision_id}] = maya.state.release_work.inbox
    assert [] = eli.state.release_work.inbox

    finish!(root_id)
  end

  @tag scenario: "HF05"
  test "Maya's durable answer resumes the same run and produces one v1 after restart" do
    room = Seeds.release_room_id()
    root = request!("@triage record my choice and continue the same release request.")
    root_id = root.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    {maya, server} = player(@maya, room, decision_id)
    supervisor = Jido.Assembly.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(supervisor, Workflow) end)

    command =
      Assembly.action(:answer_release_decision, %{target: decision_id, choice: "hold"}, maya).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: answer}}] =
             Assembly.command(command.name, command.params, server).broadcasts

    answer_id = answer.id

    assert %{
             sender_id: @maya,
             reply_to_id: ^decision_id,
             thread_id: ^root_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "decision_answer",
                 "choice" => "hold",
                 "decision_id" => ^decision_id,
                 "run_id" => ^root_id
               }
             }
           } = answer

    assert {:ok, [^answer_id]} = ChatStorage.ready_release_steps()

    assert %{status: :drafting, assignee: nil, answer: %{id: ^answer_id}} =
             Enum.find(ReleaseNotes.runs("maya"), &(&1.id == root_id))

    {answered, _server} = player(@maya, room, answer_id)
    assert answered.state.release_work.inbox == []

    assert [%{status: :drafting, items: [%{message_id: ^answer_id}]}] =
             Enum.filter(answered.state.release_work.board, &(&1.status == :drafting))

    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, [^answer_id]} = ChatStorage.ready_release_steps()
    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)
    draft_id = "release:draft:" <> root_id
    assert_receive {:signal, %Jido.Signal{id: ^draft_id}}, 3_000

    assert {:ok, record} = ChatRuntime.get_room_history(room, draft_id)

    assert %{
             role: :assistant,
             sender_id: "agent:triage",
             thread_id: ^root_id,
             reply_to_id: ^answer_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "draft",
                 "run_id" => ^root_id,
                 "answer_id" => ^answer_id,
                 "version" => 1
               }
             }
           } = Chat.message_record(record)

    assert {:ok, []} = ChatStorage.ready_release_steps()
    assert {:ok, %{id: ^draft_id}} = Workflow.advance(answer_id)

    assert [%{id: ^decision_id}, %{id: ^answer_id}, %{id: ^draft_id}] =
             Chat.list_thread_views(room, root_id)

    {eli, _server} = player(@eli, room, draft_id)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^draft_id} = eli.state
    assert [%{run_id: ^root_id, message_id: ^draft_id}] = eli.state.release_work.inbox
    review!(root_id, draft_id)
  end

  @tag scenario: "RE08"
  test "one saved choice survives conflicting replay and repeated restarts" do
    room = Seeds.release_room_id()
    root = request!("@triage recover a saved release decision in RE08.").id
    decision = ReleaseNotes.decision_anchor(root)
    {maya, server} = player(@maya, room, decision)
    supervisor = Jido.Assembly.Supervisor

    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(supervisor, Workflow) end)

    command =
      Assembly.action(
        :answer_release_decision,
        %{target: decision, choice: "document"},
        maya
      ).next_command

    assert [%Broadcast{params: %{message: answer}}] =
             Assembly.command(command.name, command.params, server).broadcasts

    answer_id = answer.id
    draft_id = "release:draft:" <> root
    assert {:ok, saved_answer} = ChatRuntime.get_room_history(room, answer_id)
    assert {:ok, nil} = ChatRuntime.get_room_history(room, draft_id)
    assert {:ok, [^answer_id]} = ChatStorage.ready_release_steps()

    conflicting =
      Assembly.action(
        :answer_release_decision,
        %{target: decision, choice: "hold"},
        maya
      ).next_command

    assert %{next_action: %{name: :release_action_failed}, broadcasts: []} =
             Assembly.command(conflicting.name, conflicting.params, server)

    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, ^saved_answer} = ChatRuntime.get_room_history(room, answer_id)
    assert {:ok, nil} = ChatRuntime.get_room_history(room, draft_id)
    assert {:ok, [^answer_id]} = ChatStorage.ready_release_steps()

    assert {:ok, subscription} = ChatRuntime.subscribe_runtime("jido.chat.room.message")
    on_exit(fn -> ChatRuntime.unsubscribe_runtime(subscription) end)

    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)
    assert_receive {:signal, %Jido.Signal{id: ^draft_id}}, 3_000
    assert {:ok, saved_draft} = ChatRuntime.get_room_history(room, draft_id)

    assert %{
             content: [
               %{text: "Prepare the release for approval and document the pending checks." <> _}
             ],
             thread_id: ^root,
             reply_to_id: ^answer_id,
             metadata: %{
               "assembly_release_note" => %{
                 "choice" => "Document the pending checks",
                 "assignee" => "eli",
                 "version" => 1
               }
             }
           } = Chat.message_record(saved_draft)

    assert {:ok, []} = ChatStorage.ready_release_steps()
    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)
    assert {:ok, %{id: ^draft_id}} = Workflow.advance(answer_id)
    assert {:ok, []} = ChatStorage.ready_release_steps()
    refute_receive {:signal, %Jido.Signal{id: ^draft_id}}, 250

    assert {:ok, ^saved_answer} = ChatRuntime.get_room_history(room, answer_id)
    assert {:ok, ^saved_draft} = ChatRuntime.get_room_history(room, draft_id)

    assert [%{id: ^decision}, %{id: ^answer_id}, %{id: ^draft_id}] =
             Chat.list_thread_views(room, root)

    {eli, _server} = player(@eli, room, draft_id)

    assert [%{message_id: ^draft_id}] =
             Enum.filter(eli.state.release_work.inbox, &(&1.run_id == root))

    review!(root, draft_id)
  end

  @tag scenario: "HF06"
  test "Eli's review points to v1 and its saved sources while Maya's queue clears" do
    room = Seeds.release_room_id()
    root = request!("@triage draft v1 with its release evidence.")
    root_id = root.id
    decision_id = ReleaseNotes.decision_anchor(root_id)
    {maya, maya_server} = player(@maya, room, decision_id)
    {eli, eli_server} = player(@eli, room)
    assert [%{message_id: ^decision_id}] = maya.state.release_work.inbox
    assert [] = eli.state.release_work.inbox

    command =
      Assembly.action(:answer_release_decision, %{target: decision_id, choice: "document"}, maya).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: draft} = event}] =
             Assembly.command(command.name, command.params, maya_server).broadcasts

    draft_id = draft.id
    assert {:ok, record} = ChatRuntime.get_room_history(room, draft_id)

    assert %{
             "type" => "draft",
             "version" => 1,
             "assignee" => "eli",
             "sources" => [
               %{"id" => "ci", "title" => "Package CI", "evidence" => ci},
               %{"id" => "live", "title" => "Live provider matrix", "evidence" => live}
             ]
           } = Chat.message_record(record).metadata["assembly_release_note"]

    maya = apply_work_event(maya, maya_server, event)
    eli = apply_work_event(eli, eli_server, event)
    assert [] = maya.state.release_work.inbox
    assert [%{run_id: ^root_id, message_id: ^draft_id, href: href}] = eli.state.release_work.inbox

    selector = ~s([aria-label="Assignments"] [data-assembly-release-target="#{draft_id}"])

    assert [^href] =
             eli
             |> release_view(eli_server, "inbox")
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute("href")

    {opened, server} = open_link(@eli, href)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^draft_id} = opened.state

    artifact =
      opened
      |> thread_dom(server)
      |> LazyHTML.query(
        ~s([data-assembly-message-id="#{draft_id}"] section[aria-label="Release note"])
      )

    assert LazyHTML.text(artifact) =~ "Release note · v1"
    assert LazyHTML.text(artifact) =~ ci
    assert LazyHTML.text(artifact) =~ live

    request_href = "/?" <> URI.encode_query(room: Seeds.release_room_id(), message: root_id)

    assert artifact |> LazyHTML.query("a") |> LazyHTML.attribute("href") |> Enum.uniq() ==
             ["/release-notes#source-ci", "/release-notes#source-live", request_href]

    review!(root_id, draft_id)
  end

  @tag scenario: "HF07"
  test "Eli saves v2 from the main thread while v1 and its sources stay readable" do
    room = Seeds.release_room_id()
    root = request!("@triage prepare a draft for Eli to revise.")
    root_id = root.id
    first = decide!(root_id)
    first_id = first.id
    {eli, eli_server} = player(@eli, room, first_id)
    selector = ~s([data-assembly-message-id="#{first_id}"] textarea[name="revision"])

    assert eli |> thread_dom(eli_server) |> LazyHTML.query(selector) |> LazyHTML.text() =~
             first.body

    revised_body =
      "Package CI passed. The pending live provider checks are listed in the sources."

    form = %{
      event: %{"target" => ReleaseNotes.message_anchor(first_id), "revision" => revised_body}
    }

    command = Assembly.action(:revise_release_artifact, form, eli).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: revised}}] =
             Assembly.command(command.name, command.params, eli_server).broadcasts

    revised_id = revised.id
    sources = first.metadata["assembly_release_note"]["sources"]

    assert %{
             body: ^revised_body,
             sender_id: @eli,
             thread_id: ^root_id,
             reply_to_id: ^first_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "revision",
                 "run_id" => ^root_id,
                 "version" => 2,
                 "parent_version_id" => ^first_id,
                 "assignee" => "maya",
                 "sources" => ^sources
               }
             }
           } = revised

    {maya, _server} = player(@maya, room)
    assert [%{message_id: ^revised_id, href: href}] = maya.state.release_work.inbox
    {opened, server} = open_link(@maya, href)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^revised_id} = opened.state
    document = thread_dom(opened, server)

    assert document
           |> LazyHTML.query(~s([data-assembly-message-id="#{first_id}"]))
           |> LazyHTML.text() =~ "Release note · v1"

    assert document
           |> LazyHTML.query(~s([data-assembly-message-id="#{revised_id}"]))
           |> LazyHTML.text() =~ "Release note · v2"

    assert document |> LazyHTML.query(selector) |> LazyHTML.to_tree() == []
    assert [%{body: body}] = Enum.filter(opened.state.thread_messages, &(&1.id == first_id))
    assert body == first.body
    review!(root_id, revised_id, "maya")
  end

  @tag scenario: "HF08"
  test "Maya approves only v2 and Board retains the approved version link" do
    room = Seeds.release_room_id()
    root_id = request!("@triage prepare a version for exact approval.").id
    v1 = decide!(root_id)

    assert {:ok, v2} =
             ReleaseNotes.submit("eli", %{
               "operation" => "revise",
               "root" => root_id,
               "target" => ReleaseNotes.message_anchor(v1.id),
               "body" => "Use the CI result and retain the live verification checklist."
             })

    v2_id = v2.id
    {maya, server} = player(@maya, room, v2_id)
    assert [%{run_id: ^root_id, message_id: ^v2_id, href: href}] = maya.state.release_work.inbox
    doc = thread_dom(maya, server)

    archived =
      LazyHTML.query(
        doc,
        ~s([data-assembly-message-id="#{v1.id}"] section[aria-label="Release note"] button)
      )

    current =
      LazyHTML.query(
        doc,
        ~s([data-assembly-message-id="#{v2_id}"] section[aria-label="Release note"] button)
      )

    assert LazyHTML.to_tree(archived) == []
    assert LazyHTML.text(current) =~ "Approve v2"

    assert {:ok, before} = ChatRuntime.list_room_history(room, thread_id: root_id)

    stale =
      Assembly.action(
        :approve_release_artifact,
        %{target: ReleaseNotes.message_anchor(v1.id)},
        maya
      ).next_command

    rejected = Assembly.command(stale.name, stale.params, server)
    assert rejected.next_action.name == :release_action_failed
    assert rejected.broadcasts == []
    assert {:ok, ^before} = ChatRuntime.list_room_history(room, thread_id: root_id)

    command =
      Assembly.action(
        :approve_release_artifact,
        %{target: ReleaseNotes.message_anchor(v2_id)},
        maya
      ).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: review} = event}] =
             Assembly.command(command.name, command.params, server).broadcasts

    assert %{
             sender_id: @maya,
             thread_id: ^root_id,
             reply_to_id: ^v2_id,
             metadata: %{
               "assembly_release_note" => %{
                 "type" => "review",
                 "run_id" => ^root_id,
                 "version_id" => ^v2_id,
                 "version" => 2
               }
             }
           } = review

    maya = apply_work_event(maya, server, event)
    assert [] = maya.state.release_work.inbox

    assert %{message_id: ^v2_id, href: ^href} =
             maya.state.release_work.board
             |> Enum.find(&(&1.status == :reviewed))
             |> Map.fetch!(:items)
             |> Enum.find(&(&1.run_id == root_id))

    selector =
      ~s([aria-label="Release board"] [data-assembly-release-lane="reviewed"] [data-assembly-release-target="#{v2_id}"])

    assert [^href] =
             maya
             |> release_view(server, "board")
             |> LazyHTML.query(selector)
             |> LazyHTML.attribute("href")

    {opened, _server} = open_link(@maya, href)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^v2_id} = opened.state
  end

  @tag scenario: "HF09"
  test "two Maya sessions can commit only one answer and continuation for the same decision" do
    room = Seeds.release_room_id()
    root_id = request!("@triage ask for a decision from two Maya sessions.").id
    decision_id = ReleaseNotes.decision_anchor(root_id)

    submissions =
      for choice <- ["document", "hold"] do
        {page, server} = player(@maya, room, decision_id)

        command =
          Assembly.action(:answer_release_decision, %{target: decision_id, choice: choice}, page).next_command

        {command, server}
      end

    [{_, first}, {_, second}] = submissions
    assert first.session_id != second.session_id

    results = race_commands!(submissions)

    [{winner, accepted}] =
      Enum.filter(results, fn {_params, result} -> result.broadcasts != [] end)

    [{_loser, rejected}] =
      Enum.filter(results, fn {_params, result} -> result.broadcasts == [] end)

    assert %{name: :release_action_failed, params: %{error: error}} = rejected.next_action
    assert error =~ "This item changed"

    assert [%Broadcast{action_name: :message_saved, params: %{message: draft}}] =
             accepted.broadcasts

    choice = winner.choice
    draft_id = draft.id

    assert [
             %{id: ^decision_id},
             %{
               id: answer_id,
               sender_id: @maya,
               metadata: %{"assembly_release_note" => %{"choice" => ^choice}}
             },
             %{id: ^draft_id, reply_to_id: parent, sender_id: "agent:triage"}
           ] = Chat.list_thread_views(room, root_id)

    assert parent == answer_id
    assert {:ok, []} = ChatStorage.ready_release_steps()
    review!(root_id, draft_id)
  end

  @tag scenario: "HF10"
  test "competing edits create one v2 and refresh the losing review session" do
    room = Seeds.release_room_id()
    root_id = request!("@triage prepare a draft for two concurrent edits.").id
    v1 = decide!(root_id)
    v1_id = v1.id

    views =
      for body <- ["Use the passed CI evidence first.", "Lead with the pending provider checks."] do
        {page, server} = player(@eli, room, v1_id)
        form = %{"target" => ReleaseNotes.message_anchor(v1_id), "revision" => body}
        command = Assembly.action(:revise_release_artifact, form, page).next_command
        %{page: page, server: server, command: command}
      end

    results = race_commands!(Enum.map(views, &{&1.command, &1.server}))

    [{winner, accepted}] =
      Enum.filter(results, fn {_params, result} -> result.broadcasts != [] end)

    loser_index = Enum.find_index(results, fn {_params, result} -> result.broadcasts == [] end)
    {_attrs, rejected} = Enum.at(results, loser_index)

    assert %{name: :release_action_failed, params: %{refresh: true} = error} =
             rejected.next_action

    assert [%Broadcast{action_name: :message_saved, params: %{message: v2}}] = accepted.broadcasts
    v2_id = v2.id
    assert v2.body == winner.body
    assert v2.reply_to_id == v1_id

    assert [%{id: ^v1_id}, %{id: ^v2_id}] =
             Chat.list_thread_views(room, root_id)
             |> Enum.filter(fn message ->
               message.metadata["assembly_release_note"]["type"] in ["draft", "revision"]
             end)

    %{page: loser, server: server} = Enum.at(views, loser_index)
    loser = Assembly.action(:release_action_failed, error, loser)

    assert %{name: :load_room_history, params: %{refresh_release_work: true} = params} =
             loser.next_command

    assert %{name: :room_history_loaded, params: refreshed} =
             Assembly.command(:load_room_history, params, server).next_action

    loser = Assembly.action(:room_history_loaded, refreshed, loser)
    assert loser.state.thread_root.id == root_id
    assert Enum.any?(loser.state.thread_messages, &(&1.id == v2_id))
    assert loser.state.release_work.inbox == []

    assert %{status: :review, assignee: "maya", note: %{id: ^v2_id}} =
             Enum.find(ReleaseNotes.runs("maya"), &(&1.id == root_id))

    review!(root_id, v2_id, "maya")
  end

  @tag scenario: "HF11"
  test "completing Maya's release request leaves Eli's own handoff and exact link unchanged" do
    room = Seeds.release_room_id()
    maya_root = request!("@triage prepare a separate release note for Maya.")
    eli_root = request!("@triage prepare another release note for Eli.", "eli")
    maya_id = maya_root.id
    eli_id = eli_root.id
    maya_decision = ReleaseNotes.decision_anchor(maya_id)
    eli_decision = ReleaseNotes.decision_anchor(eli_id)
    {maya, _maya_server} = player(@maya, room)
    {eli, eli_server} = player(@eli, room)
    assert [%{run_id: ^maya_id, message_id: ^maya_decision}] = maya.state.release_work.inbox

    assert [%{run_id: ^eli_id, message_id: ^eli_decision} = independent] =
             eli.state.release_work.inbox

    assert {:ok, independent_history} = ChatRuntime.list_room_history(room, thread_id: eli_id)

    draft = decide!(maya_id)
    draft_id = draft.id
    assert {:ok, record} = ChatRuntime.get_room_history(room, draft_id)
    assert {:ok, event} = RuntimeNotifier.message_saved_params(record.signal)
    eli = apply_work_event(eli, eli_server, event)

    assert Enum.member?(eli.state.release_work.inbox, independent)

    assert %{run_id: ^maya_id, message_id: ^draft_id} =
             Enum.find(eli.state.release_work.inbox, &(&1.run_id == maya_id))

    assert length(eli.state.release_work.inbox) == 2

    review = review!(maya_id, draft_id)
    assert {:ok, record} = ChatRuntime.get_room_history(room, review.id)
    assert {:ok, event} = RuntimeNotifier.message_saved_params(record.signal)
    eli = apply_work_event(eli, eli_server, event)
    assert [^independent] = eli.state.release_work.inbox
    assert {:ok, ^independent_history} = ChatRuntime.list_room_history(room, thread_id: eli_id)

    {opened, _server} = open_link(@eli, independent.href)
    assert %{thread_root: %{id: ^eli_id}, focused_message_id: ^eli_decision} = opened.state

    assert %{status: :reviewed, assignee: nil} =
             Enum.find(ReleaseNotes.runs("maya"), &(&1.id == maya_id))

    assert %{status: :decision, assignee: "eli"} =
             Enum.find(ReleaseNotes.runs("eli"), &(&1.id == eli_id))

    independent_draft = decide!(eli_id, "eli")
    review!(eli_id, independent_draft.id, "maya")
  end

  @tag scenario: "HF12"
  test "a pending v2 survives SQLite restart and opens from Needs you beyond the latest page" do
    room = Seeds.release_room_id()
    root_id = request!("@triage prepare a release note with a review to restore.").id
    first = decide!(root_id)

    assert {:ok, v2} =
             ReleaseNotes.submit("eli", %{
               "operation" => "revise",
               "root" => root_id,
               "target" => ReleaseNotes.message_anchor(first.id),
               "body" => "Preserve the exact review target across a restart."
             })

    v2_id = v2.id

    for index <- 1..55 do
      assert {:ok, _message} = Chat.send_message(room, "Unrelated channel update #{index}.", @eli)
    end

    assert {:ok, page} = Chat.room_history_page(room, @maya)
    refute Map.has_key?(page.threads, root_id)
    refute Enum.any?(page.messages, &(&1.id == root_id))
    {before, _server} = player(@maya, room)

    assert [%{run_id: ^root_id, message_id: ^v2_id, href: href} = assignment] =
             before.state.release_work.inbox

    assert {:ok, history} = ChatRuntime.list_room_history(room, thread_id: root_id)
    supervisor = Jido.Assembly.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(supervisor, Workflow) end)
    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)

    assert {:ok, ^history} = ChatRuntime.list_room_history(room, thread_id: root_id)
    {restored, _server} = player(@maya, room)
    assert [^assignment] = restored.state.release_work.inbox
    {opened, server} = open_link(@maya, href)
    assert %{thread_root: %{id: ^root_id}, focused_message_id: ^v2_id} = opened.state
    assert Enum.any?(opened.state.thread_messages, &(&1.id == v2_id))

    command =
      Assembly.action(
        :approve_release_artifact,
        %{target: ReleaseNotes.message_anchor(v2_id)},
        opened
      ).next_command

    accepted = Assembly.command(command.name, command.params, server)

    assert [%Broadcast{action_name: :message_saved, params: %{message: review}}] =
             accepted.broadcasts

    assert review.reply_to_id == v2_id
    {_opened_again, second_session} = open_link(@maya, href)
    rejected = Assembly.command(command.name, command.params, second_session)
    assert rejected.next_action.name == :release_action_failed
    assert rejected.broadcasts == []

    {finished, _server} = player(@maya, room)
    assert [] = finished.state.release_work.inbox

    assert %{status: :reviewed, note: %{id: ^v2_id}} =
             Enum.find(ReleaseNotes.runs("maya"), &(&1.id == root_id))
  end

  @tag scenario: "RE10"
  test "Needs you and Board rebuild from saved roots and preserve assignment order" do
    room = Seeds.release_room_id()
    older = request!("@triage record the first finished release for RE10.").id
    older_draft = decide!(older)
    review!(older, older_draft.id)
    newer = request!("@triage record the second finished release for RE10.").id
    newer_draft = decide!(newer)
    review!(newer, newer_draft.id)

    in_review = request!("@triage ask Maya to review this release for RE10.", "eli").id
    draft = decide!(in_review, "eli")
    for_decision = request!("@triage ask Maya for another decision for RE10.").id
    decision_id = ReleaseNotes.decision_anchor(for_decision)
    draft_id = draft.id

    {maya, _server} = player(@maya, room)
    {eli, _server} = player(@eli, room)
    maya_work = maya.state.release_work
    eli_work = eli.state.release_work

    assert [
             %{run_id: ^for_decision, message_id: ^decision_id, href: decision_href},
             %{run_id: ^in_review, message_id: ^draft_id, href: draft_href}
           ] = maya_work.inbox

    assert eli_work.inbox == []
    assert maya_work.board == eli_work.board
    assert %{items: reviewed} = Enum.find(maya_work.board, &(&1.status == :reviewed))

    assert Enum.map(Enum.filter(reviewed, &(&1.run_id in [older, newer])), & &1.message_id) ==
             [newer_draft.id, older_draft.id]

    supervisor = Jido.Assembly.Supervisor
    assert :ok = Supervisor.terminate_child(supervisor, Workflow)
    on_exit(fn -> Supervisor.restart_child(supervisor, Workflow) end)
    assert :ok = Supervisor.terminate_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, ChatStorage)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Workflow)

    {maya, maya_server} = player(@maya, room)
    {eli, eli_server} = player(@eli, room)
    assert maya.state.release_work == maya_work
    assert eli.state.release_work == eli_work
    counter = "[data-assembly-needs-count]"

    assert maya |> sidebar_dom(maya_server) |> LazyHTML.query(counter) |> LazyHTML.text() == "2"
    assert eli |> sidebar_dom(eli_server) |> LazyHTML.query(counter) |> LazyHTML.to_tree() == []

    {opened, _server} = open_link(@maya, decision_href)
    assert %{thread_root: %{id: ^for_decision}, focused_message_id: ^decision_id} = opened.state
    {opened, _server} = open_link(@maya, draft_href)
    assert %{thread_root: %{id: ^in_review}, focused_message_id: ^draft_id} = opened.state

    finish!(for_decision)
    review!(in_review, draft_id, "maya")
  end

  @tag scenario: "RE12"
  test "out-of-order snapshots and repeated revision events converge in both players' views" do
    room = Seeds.release_room_id()
    root = request!("@triage keep the current review when snapshots overlap in RE12.").id
    v1 = decide!(root)
    {maya, maya_server} = player(@maya, room, v1.id)
    {eli, eli_server} = player(@eli, room, v1.id)
    assert [%{message_id: v1_id}] = eli.state.release_work.inbox
    assert v1_id == v1.id
    assert maya.state.release_work.inbox == []

    old_snapshot =
      Assembly.command(:load_snapshot, %{active_room_id: room}, maya_server).next_action

    old_work = Assembly.command(:load_release_work, %{}, maya_server).next_action

    old_history =
      Assembly.command(
        :load_room_history,
        %{room_id: room, before: nil, refresh_release_work: true},
        eli_server
      ).next_action

    command =
      Assembly.action(
        :revise_release_artifact,
        %{"target" => ReleaseNotes.message_anchor(v1.id), "revision" => "Keep the current v2."},
        eli
      ).next_command

    assert [%Broadcast{action_name: :message_saved, params: %{message: v2}}] =
             Assembly.command(command.name, command.params, eli_server).broadcasts

    v2_id = v2.id
    assert {:ok, record} = ChatRuntime.get_room_history(room, v2_id)
    assert {:ok, event} = RuntimeNotifier.message_saved_params(record.signal)

    latest_snapshot =
      Assembly.command(:load_snapshot, %{active_room_id: room}, eli_server).next_action

    maya = apply_work_event(maya, maya_server, event)
    maya = Assembly.action(old_snapshot.name, old_snapshot.params, maya)
    maya = Assembly.action(old_work.name, old_work.params, maya)
    eli = Assembly.action(latest_snapshot.name, latest_snapshot.params, eli)
    eli = apply_work_event(eli, eli_server, event)
    eli = Assembly.action(:message_saved, event, eli)
    eli = Assembly.action(old_history.name, old_history.params, eli)

    assert {:ok, history} = ChatRuntime.list_room_history(room, thread_id: root)
    expected = Enum.map(history, & &1.message_id)
    assert List.last(expected) == v2_id

    for page <- [maya, eli] do
      assert Enum.map(page.state.thread_messages, & &1.id) == expected

      assert [%{id: ^root, reply_count: reply_count}] =
               Enum.filter(page.state.messages, &(&1.id == root))

      assert reply_count == length(expected)
      refute Enum.any?(page.state.messages, &(&1.id in expected))
    end

    assert [%{run_id: ^root, message_id: ^v2_id}] = maya.state.release_work.inbox
    assert eli.state.release_work.inbox == []
    assert maya.state.release_work.board == eli.state.release_work.board

    assert %{items: [%{run_id: ^root, message_id: ^v2_id}]} =
             Enum.find(maya.state.release_work.board, &(&1.status == :review))

    dom = thread_dom(maya, maya_server)
    archived = ~s([data-assembly-message-id="#{v1.id}"] section[aria-label="Release note"] button)
    current = ~s([data-assembly-message-id="#{v2_id}"] section[aria-label="Release note"] button)
    assert dom |> LazyHTML.query(archived) |> LazyHTML.to_tree() == []
    assert dom |> LazyHTML.query(current) |> LazyHTML.text() =~ "Approve v2"
    review!(root, v2_id, "maya")
  end

  defp race_commands!(submissions) do
    parent = self()

    tasks =
      for {command, server} <- submissions do
        Task.async(fn ->
          send(parent, {:release_ready, self()})

          receive do
            :submit -> {command.params, Assembly.command(command.name, command.params, server)}
          end
        end)
      end

    for %{pid: pid} <- tasks do
      assert_receive {:release_ready, ^pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :submit))
    Task.await_many(tasks, 5_000)
  end

  defp thread_dom(page, server) do
    {html, _components, _state} =
      Renderer.render_dom(
        ThreadPanel.template().(Map.put(page.state, :mobile, false)),
        %Env{},
        server
      )

    LazyHTML.from_document(html)
  end

  defp apply_work_event(page, server, event) do
    page = Assembly.action(:message_saved, event, page)
    assert %{name: :load_release_work, params: params} = page.next_command

    assert %{name: :release_work_loaded, params: work} =
             Assembly.command(:load_release_work, params, server).next_action

    Assembly.action(:release_work_loaded, work, page)
  end

  defp release_view(page, server, view) do
    page = Assembly.action(:show_workspace_view, %{view: view}, page)

    attrs = %{
      work: page.state.release_work,
      channels: page.state.channels,
      view: page.state.workspace_view
    }

    {html, _components, _state} =
      Renderer.render_dom(ReleaseWork.template().(attrs), %Env{}, server)

    LazyHTML.from_document(html)
  end

  defp sidebar_dom(page, server) do
    {html, _components, _state} =
      Renderer.render_dom(Sidebar.template().(page.state), %Env{}, server)

    LazyHTML.from_document(html)
  end

  defp open_link(user, href) do
    %{"room" => room, "message" => message} =
      href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    player(user, room, message)
  end

  defp player(user, room, message \\ nil) do
    query = if message, do: %{"room" => room, "message" => message}, else: %{"room" => room}
    session = "release-workflow-#{user}-#{System.unique_integer([:positive])}"

    init_page(Assembly, %{},
      session_id: session,
      instance_id: session,
      user_id: user,
      query: query
    )
  end

  defp request!(body, person \\ "maya") do
    assert {:ok, root} = ReleaseNotes.submit(person, %{"operation" => "request", "body" => body})
    root
  end

  defp decide!(root, person \\ "maya") do
    assert {:ok, draft} =
             ReleaseNotes.submit(person, %{
               "operation" => "decide",
               "root" => root,
               "target" => ReleaseNotes.decision_anchor(root),
               "choice" => "document"
             })

    draft
  end

  defp review!(root, draft_id, person \\ "eli") do
    sender_id = "user:" <> person

    assert {:ok, %{sender_id: ^sender_id} = review} =
             ReleaseNotes.submit(person, %{
               "operation" => "review",
               "root" => root,
               "target" => ReleaseNotes.message_anchor(draft_id)
             })

    review
  end

  defp finish!(root), do: review!(root, decide!(root).id)
end
