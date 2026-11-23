defmodule Jido.Assembly.ReleaseNotes do
  @moduledoc """
  Scripted release-note collaboration over durable Jido Chat threads.

  Each request and transition is a room message. The worker uses committed
  inputs and stable IDs to publish the scripted Triage responses.
  """

  alias Jido.Assembly.{Chat, ChatRuntime, Pilot, Seeds}
  alias Jido.Assembly.Chat.{Mentions, Projections}
  alias Jido.Assembly.ReleaseNotes.{Publication, Workflow}
  alias Jido.Chat.Runtime.Room.HistoryRecord

  @people %{"maya" => {"user:maya", "Maya Reyes"}, "eli" => {"user:eli", "Eli Park"}}
  @other %{"maya" => "eli", "eli" => "maya"}
  @agent "agent:triage"
  @event "assembly_release_note"
  @decision_prompt "Should we wait for all live checks or document the pending checks?"
  @source_page [
    {"ci", "Package CI", "The sample package run passed compile, lint, and automated tests."},
    {"live", "Live provider matrix", "Discord, Slack, Signal, and X have pending live checks."}
  ]
  @choices %{
    "hold" => "Wait for full live coverage",
    "document" => "Document the pending checks"
  }
  @board_lanes [:starting, :decision, :drafting, :review, :reviewed, :cancelled]
  @history_page_size 50

  def sources, do: @source_page

  def sources(%{"sources" => sources}) when is_list(sources) do
    for %{"id" => id, "title" => title, "evidence" => evidence} <- sources,
        is_binary(id) and is_binary(title) and is_binary(evidence),
        do: {id, title, evidence}
  end

  def sources(_legacy), do: sources()

  def choices(run), do: Enum.sort(run.allowed_choices)
  def people, do: Enum.map(["maya", "eli"], &{&1, name(&1)})
  def name(person), do: elem(Map.fetch!(@people, person), 1)
  def viewer(person) when person in ["maya", "eli"], do: person
  def viewer(_person), do: "maya"

  def person_for("user:" <> person) when is_map_key(@people, person), do: {:ok, person}
  def person_for(_id), do: :error

  def request_from_chat(room_id, user_id, body) do
    with false <- Pilot.enabled?(),
         true <- room_id == Seeds.release_room_id(),
         {:ok, person} <- person_for(user_id),
         true <- triage_mentioned?(body) do
      in_release_room(person, &request_command(person, body, &1))
    else
      _other -> :ordinary_post
    end
  end

  def runs(person) when is_map_key(@people, person) do
    case fetch_runs(person) do
      {:ok, runs, _sequence} -> runs
      {:error, _reason} -> []
    end
  end

  defp fetch_runs(person) do
    with {:ok, records} <- release_history(Seeds.release_room_id(), nil, []) do
      messages =
        Enum.map(records, fn record ->
          record
          |> Chat.message_record()
          |> Projections.message_view(actor(person))
        end)

      {roots, replies} = Enum.split_with(messages, &is_nil(&1.thread_id))

      sequence =
        case List.last(records) do
          nil -> 0
          record -> record.sequence
        end

      {:ok, project_runs(roots, Enum.group_by(replies, & &1.thread_id)), sequence}
    end
  end

  defp release_history(room_id, after_id, acc) do
    opts = [limit: @history_page_size]
    opts = if after_id, do: Keyword.put(opts, :after, after_id), else: opts

    with {:ok, page} <- ChatRuntime.list_room_history(room_id, opts) do
      events =
        Enum.filter(page, fn record ->
          match?(
            %{metadata: %{@event => event}} when is_map(event),
            Projections.message_from_fact(record.signal)
          )
        end)

      acc = Enum.reverse(events, acc)

      if length(page) < @history_page_size,
        do: {:ok, Enum.reverse(acc)},
        else: release_history(room_id, List.last(page).message_id, acc)
    end
  end

  defp project_runs(roots, threads) do
    for root <- roots,
        %{"type" => "request", "person" => requester} = request <- [event(root)],
        is_map_key(@people, requester),
        root.sender_id == actor(requester) do
      replies = Map.get(threads, root.id, [])

      decision =
        Enum.find(replies, fn reply ->
          reply.id == decision_anchor(root.id) and reply.sender_id == @agent and
            match?(%{"type" => "decision", "run_id" => id} when id == root.id, event(reply))
        end)

      answer =
        Enum.find(replies, fn reply ->
          reply.id == answer_id(root.id) and reply.sender_id == root.sender_id and
            match?(
              %{"type" => "decision_answer", "run_id" => id} when id == root.id,
              event(reply)
            )
        end)

      changes =
        for reply <- replies,
            %{"type" => type} = data <- [event(reply)],
            type in ["draft", "revision", "review"],
            do: %{
              id: reply.id,
              author: reply.author,
              text: reply.body,
              data: data,
              permalink: reply.permalink
            }

      cancellation =
        Enum.find(replies, fn reply ->
          reply.id == cancellation_id(root.id) and reply.sender_id == root.sender_id and
            match?(%{"type" => "cancelled", "run_id" => id} when id == root.id, event(reply))
        end)

      run_view(root, requester, decision, answer, changes, request, cancellation)
    end
    |> Enum.reverse()
  end

  def inbox(runs, person), do: Enum.filter(runs, &(&1.assignee == person))

  def work_view(user_id) do
    with false <- Pilot.enabled?(),
         {:ok, person} <- person_for(user_id),
         {:ok, runs, sequence} <- fetch_runs(person) do
      by_status = Enum.group_by(runs, & &1.status, &work_item/1)

      board =
        for status <- @board_lanes, items = Map.get(by_status, status, []), items != [] do
          %{status: status, label: status_label(status), items: items}
        end

      %{
        inbox: runs |> inbox(person) |> Enum.map(&work_item/1),
        board: board,
        through_sequence: sequence
      }
    else
      _unavailable -> nil
    end
  end

  def board_lanes, do: @board_lanes
  def status_label(:starting), do: "Preparing decision"
  def status_label(:decision), do: "Decision needed"
  def status_label(:drafting), do: "Preparing draft"
  def status_label(:review), do: "Ready for review"
  def status_label(:reviewed), do: "Reviewed"
  def status_label(:cancelled), do: "Cancelled"

  def error_to_string(:mention_required), do: "Mention @triage to start a release-note thread."

  def error_to_string(:request_pending),
    do: "Finish the review on your open request before starting another."

  def error_to_string(:room_unavailable),
    do: "The release room is unavailable. Try again shortly."

  def error_to_string(:empty_message), do: "Enter the revised release note."

  def error_to_string(:edit_required),
    do: "Change the release note before submitting the revision."

  def error_to_string(:message_too_long), do: "Use 2,000 characters or fewer."

  def error_to_string(:stale_action),
    do: "This item changed or belongs to another reviewer. Open the current request."

  def error_to_string(:review_required),
    do: "Mark this version reviewed before approving publication."

  def error_to_string(_reason),
    do: "Assembly could not save that action. Check the thread before trying again."

  defp work_item(run) do
    message = run.cancellation || run.note || run.answer || run.decision || run.root
    title = if run.note, do: "Release note v#{run.note.data["version"]}", else: "Release criteria"

    %{
      run_id: run.id,
      message_id: message.id,
      href: message.permalink,
      title: title,
      request: run.root.body
    }
  end

  def submit(person, attrs) when is_map_key(@people, person) and is_map(attrs) do
    in_release_room(person, &apply_action(person, attrs, &1))
  end

  def submit(_person, _attrs), do: {:error, :invalid_action}

  defp in_release_room(person, fun) do
    # Serialize state checks with the durable input write.
    room = Seeds.release_room_id()

    :global.trans(
      {{__MODULE__, room}, self()},
      fn ->
        # The manager hydrates persisted rooms asynchronously on a cold boot.
        case ChatRuntime.room_runtime_status(room) do
          {:ok, %{state: :running}} ->
            with {:ok, runs, _sequence} <- fetch_runs(person), do: fun.(runs)

          _ ->
            {:error, :room_unavailable}
        end
      end,
      [node()]
    )
  end

  defp apply_action(person, %{"operation" => "request", "body" => body}, runs)
       when is_binary(body) do
    with {:ok, request, _signals} <- request_command(person, body, runs), do: {:ok, request}
  end

  defp apply_action(
         person,
         %{"operation" => "cancel_release", "root" => root, "target" => target},
         runs
       ) do
    with %{requester: ^person} = run <- Enum.find(runs, &(&1.id == root)),
         true <- target == message_anchor(root) do
      cancel(run, person)
    else
      _mismatch -> {:error, :stale_action}
    end
  end

  defp apply_action(
         person,
         %{"operation" => "propose_publish", "root" => root, "target" => target},
         runs
       ) do
    with %{status: status, note: %{id: version, data: %{"assignee" => ^person}}} = run
         when status in [:review, :reviewed] <- Enum.find(runs, &(&1.id == root)),
         true <- target == message_anchor(version) do
      Publication.propose(run, person)
    else
      _mismatch -> {:error, :stale_action}
    end
  end

  defp apply_action(
         person,
         %{"operation" => operation, "root" => root, "target" => target},
         runs
       )
       when operation in ["approve_publish", "revoke_publish"] do
    with %{status: status, note: %{data: %{"assignee" => ^person}}} = run
         when status in [:review, :reviewed] <- Enum.find(runs, &(&1.id == root)) do
      Publication.submit(run, person, target, operation)
    else
      _mismatch -> {:error, :stale_action}
    end
  end

  defp apply_action(
         person,
         %{"operation" => operation, "root" => root, "target" => target} = attrs,
         runs
       ) do
    with %{assignee: ^person, target: ^target} = run <- Enum.find(runs, &(&1.id == root)) do
      transition(operation, run, person, attrs)
    else
      _ -> {:error, :stale_action}
    end
  end

  defp apply_action(_person, _attrs, _runs), do: {:error, :invalid_action}

  defp cancel(%{cancellation: %{id: id}}, person), do: Chat.get_message_view(id, actor(person))

  defp cancel(run, person) do
    with :ok <- Publication.allow_cancellation(run) do
      post(
        "Cancelled this release run.",
        actor(person),
        %{"type" => "cancelled", "run_id" => run.id, "person" => person},
        message_id: cancellation_id(run.id),
        thread_id: run.id,
        reply_to_id: run.id
      )
    end
  end

  defp request_command(person, body, runs) do
    cond do
      String.length(body) > 2_000 ->
        {:error, :message_too_long}

      not triage_mentioned?(body) ->
        {:error, :mention_required}

      Enum.any?(runs, &(&1.requester == person and &1.status not in [:reviewed, :cancelled])) ->
        {:error, :request_pending}

      true ->
        opts = Application.get_env(:jido_assembly, :agent_trigger_options, [])

        metadata = %{
          @event => %{
            "type" => "request",
            "person" => person,
            "workflow" => 1,
            "delegate" => Keyword.get(opts, :release_delegation, false),
            "publication_recommendation" =>
              Keyword.get(opts, :release_publication_recommendation, false),
            "peer_context" => Keyword.get(opts, :release_peer_context, true),
            "rollout_required" => Keyword.get(opts, :release_rollout_required, true)
          }
        }

        with {:ok, request, _signals} = result <-
               Chat.send_message_command(Seeds.release_room_id(), body, actor(person),
                 metadata: metadata
               ) do
          _ = Workflow.advance(request.id)
          result
        end
    end
  end

  defp triage_mentioned?(body), do: @agent in Mentions.mentioned_user_ids(body)

  defp transition("decide", %{status: :decision} = run, person, %{"choice" => choice})
       when is_map_key(@choices, choice) do
    with {:ok, label} <- Map.fetch(run.allowed_choices, choice) do
      parent = if run.decision, do: run.decision.id, else: run.id

      data = %{
        "type" => "decision_answer",
        "run_id" => run.id,
        "decision_id" => parent,
        "person" => person,
        "choice" => choice,
        "label" => label
      }

      with {:ok, answer} <-
             post(label, actor(person), data,
               thread_id: run.id,
               reply_to_id: parent,
               message_id: answer_id(run.id)
             ) do
        case Workflow.advance(answer.id) do
          {:ok, _draft} = result -> result
          {:error, _reason} -> {:ok, answer}
        end
      end
    else
      :error -> {:error, :invalid_action}
    end
  end

  defp transition("revise", %{status: :review} = run, person, %{"body" => body})
       when is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:error, :empty_message}

      String.length(body) > 2_000 ->
        {:error, :message_too_long}

      body == run.note.text ->
        {:error, :edit_required}

      true ->
        version = run.note.data["version"] + 1

        data = %{
          "type" => "revision",
          "run_id" => run.id,
          "parent_version_id" => run.note.id,
          "person" => person,
          "assignee" => @other[person],
          "version" => version,
          "sources" => source_metadata(run.note.data)
        }

        post(body, actor(person), data,
          message_id: "release:version:#{version}:" <> run.id,
          thread_id: run.id,
          reply_to_id: run.note.id
        )
    end
  end

  defp transition("review", %{status: :review} = run, person, _attrs) do
    version_id = run.note.id
    version = run.note.data["version"]

    post(
      "Marked release note v#{version} reviewed.",
      actor(person),
      %{
        "type" => "review",
        "person" => person,
        "run_id" => run.id,
        "version_id" => version_id,
        "version" => version
      },
      message_id: "release:review:" <> version_id,
      thread_id: run.id,
      reply_to_id: version_id
    )
  end

  defp transition(_operation, _run, _person, _attrs), do: {:error, :invalid_action}

  defp run_view(root, requester, decision, answer, changes, request, cancellation) do
    note = Enum.find(Enum.reverse(changes), &(&1.data["type"] in ["draft", "revision"]))
    saved_decision = if decision, do: event(decision)

    {status, assignee, target} =
      case cancellation || List.last(changes) do
        %{id: id, metadata: %{@event => %{"type" => "cancelled"}}} ->
          {:cancelled, nil, message_anchor(id)}

        %{data: %{"type" => "review"}} ->
          {:reviewed, nil, message_anchor(note.id)}

        %{id: id, data: %{"assignee" => assignee}} ->
          {:review, assignee, message_anchor(id)}

        nil when not is_nil(answer) ->
          {:drafting, nil, message_anchor(answer.id)}

        nil ->
          pending_decision(root.id, requester, saved_decision, request)
      end

    %{
      id: root.id,
      root: root,
      requester: requester,
      decision: decision,
      answer: answer,
      cancellation: cancellation,
      decision_prompt: if(decision, do: decision.body, else: @decision_prompt),
      allowed_choices: if(saved_decision, do: saved_decision["choices"], else: @choices),
      changes: changes,
      note: note,
      status: status,
      assignee: assignee,
      target: target
    }
  end

  defp pending_decision(id, _requester, %{"assignee" => assignee}, _request),
    do: {:decision, assignee, decision_anchor(id)}

  defp pending_decision(id, _requester, nil, %{"workflow" => 1}),
    do: {:starting, nil, decision_anchor(id)}

  defp pending_decision(id, requester, nil, _legacy),
    do: {:decision, requester, decision_anchor(id)}

  @doc false
  def workflow_step(%HistoryRecord{} = record) do
    if record.room_id == Seeds.release_room_id() do
      record.signal
      |> Projections.message_from_fact()
      |> step_from_message()
    end
  end

  defp step_from_message(%{
         id: id,
         role: :user,
         actor: %{kind: :human, id: "user:" <> person},
         thread_id: root,
         reply_to_id: root,
         metadata: %{@event => %{"type" => "cancelled", "run_id" => root, "person" => person}}
       })
       when is_map_key(@people, person) and is_binary(root) do
    if id == cancellation_id(root),
      do: {:cancel, %{person: person, input_ids: [root, answer_id(root)]}}
  end

  defp step_from_message(%{
         id: id,
         role: :user,
         actor: %{kind: :human, id: "user:" <> person},
         thread_id: nil,
         metadata: %{@event => %{"type" => "request", "person" => person, "workflow" => 1}}
       })
       when is_map_key(@people, person),
       do: {:queue, %{type: :decision, id: id, person: person}}

  defp step_from_message(%{
         id: id,
         role: :user,
         actor: %{kind: :human, id: "user:" <> person},
         thread_id: root,
         reply_to_id: decision,
         metadata: %{
           @event => %{
             "type" => "decision_answer",
             "run_id" => root,
             "decision_id" => decision,
             "person" => person,
             "choice" => choice,
             "label" => label
           }
         }
       })
       when is_map_key(@people, person) and is_map_key(@choices, choice) and is_binary(label) do
    if id == answer_id(root) and decision in [decision_anchor(root), root] do
      {:queue, %{type: :draft, id: id, root: root, person: person, choice: choice, label: label}}
    end
  end

  defp step_from_message(%{
         id: id,
         role: :assistant,
         actor: %{id: @agent},
         thread_id: root_id,
         reply_to_id: root_id,
         metadata: %{@event => %{"type" => "decision", "run_id" => root_id}}
       }) do
    if id == decision_anchor(root_id), do: {:complete, root_id}
  end

  defp step_from_message(%{
         id: id,
         role: :assistant,
         actor: %{id: @agent},
         thread_id: root,
         reply_to_id: answer,
         metadata: %{
           @event => %{"type" => "draft", "run_id" => root, "answer_id" => answer, "version" => 1}
         }
       }) do
    if id == draft_id(root) and answer == answer_id(root), do: {:complete, answer}
  end

  defp step_from_message(message), do: Publication.workflow_step(message)

  @doc false
  def cancellation_owner?(%HistoryRecord{} = record, person) do
    match?(
      %{
        role: :user,
        actor: %{kind: :human, id: "user:" <> ^person},
        thread_id: nil,
        metadata: %{@event => %{"type" => "request", "person" => ^person}}
      },
      Projections.message_from_fact(record.signal)
    )
  end

  @doc false
  def run_step(id) do
    with {:ok, %HistoryRecord{} = record} <-
           ChatRuntime.get_room_history(Seeds.release_room_id(), id),
         {:queue, %{id: ^id} = step} <- workflow_step(record) do
      publish_step(step)
    else
      _unavailable -> {:error, :release_step_unavailable}
    end
  end

  defp publish_step(%{type: :decision, id: id, person: person}) do
    post_step(
      @decision_prompt,
      @agent,
      %{"type" => "decision", "run_id" => id, "assignee" => person, "choices" => @choices},
      message_id: decision_anchor(id),
      thread_id: id,
      reply_to_id: id,
      role: :assistant
    )
  end

  defp publish_step(%{
         type: :draft,
         id: answer,
         root: root,
         person: person,
         choice: choice,
         label: label
       }) do
    data = %{
      "type" => "draft",
      "run_id" => root,
      "answer_id" => answer,
      "person" => person,
      "choice" => label,
      "assignee" => @other[person],
      "version" => 1,
      "sources" => source_metadata(%{})
    }

    post_step(draft(choice), @agent, data,
      message_id: draft_id(root),
      thread_id: root,
      reply_to_id: answer,
      role: :assistant
    )
  end

  defp publish_step(%{type: :publish} = step), do: Publication.execute(step)

  defp post_step(body, sender, event, opts) do
    id = Keyword.fetch!(opts, :message_id)

    case ChatRuntime.get_room_history(Seeds.release_room_id(), id) do
      {:ok, nil} -> post(body, sender, event, opts)
      {:ok, _record} -> Chat.get_message_view(id, sender)
      {:error, _reason} = error -> error
    end
  end

  def decision_anchor(root_id), do: "decision-" <> root_id
  def message_anchor(id), do: "message-" <> id
  def cancellation_id(root), do: "release:cancel:" <> root
  defp answer_id(root), do: "release:answer:" <> root
  defp draft_id(root), do: "release:draft:" <> root

  defp source_metadata(data) do
    for {id, title, evidence} <- sources(data),
        do: %{"id" => id, "title" => title, "evidence" => evidence}
  end

  defp event(message), do: message.metadata[@event]
  defp actor(person), do: elem(Map.fetch!(@people, person), 0)

  defp post(body, sender, event, opts) do
    Chat.send_message(
      Seeds.release_room_id(),
      body,
      sender,
      Keyword.put(opts, :metadata, %{@event => event})
    )
  end

  defp draft("hold"),
    do: "Hold the release until the live provider checks pass.\n\n" <> evidence()

  defp draft("document"),
    do: "Prepare the release for approval and document the pending checks.\n\n" <> evidence()

  defp evidence do
    "Package CI passed in the sample run. Live checks are pending for Discord, Slack, Signal, and X."
  end
end
