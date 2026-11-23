defmodule Jido.Assembly.ReleaseNotes.Publication do
  @moduledoc "Records the proposed operation, human approval, and publish receipt."

  alias Jido.Assembly.{Chat, ChatRuntime, ReleaseNotes, Seeds}
  alias Jido.Assembly.Agents.Actions.PublishReleaseNote
  alias Jido.Assembly.Chat.Projections
  alias Jido.Assembly.ReleaseNotes.Workflow

  @agent "agent:triage"
  @event "assembly_release_note"

  def action, do: PublishReleaseNote.name()
  def proposal_id(version_id), do: "release:publish:proposal:" <> version_id
  def approval_id(proposal_id), do: "release:publish:approval:" <> proposal_id
  def revocation_id(proposal_id), do: "release:publish:revocation:" <> proposal_id
  def receipt_id(approval_id), do: "release:publish:receipt:" <> approval_id
  def uncertainty_id(approval_id), do: "release:publish:uncertain:" <> approval_id
  def destination_message_id(approval_id), do: "release:publish:post:" <> approval_id

  def allow_cancellation(%{note: nil}), do: :ok

  def allow_cancellation(%{note: %{id: version_id}}),
    do: require_absent(approval_id(proposal_id(version_id)))

  def propose(run, approver) do
    destination = %{"id" => Seeds.release_log_room_id(), "name" => "#release-log"}
    version = run.note.data["version"]

    proposal = %{
      "type" => "publish_proposal",
      "run_id" => run.id,
      "version_id" => run.note.id,
      "version" => version,
      "destination" => destination,
      "action" => action(),
      "approver" => approver
    }

    Chat.send_message(
      Seeds.release_room_id(),
      "Prepared a publish proposal for v#{version}.",
      @agent,
      message_id: proposal_id(run.note.id),
      thread_id: run.id,
      reply_to_id: run.note.id,
      role: :assistant,
      metadata: %{@event => proposal}
    )
  end

  def submit(run, person, target, operation) do
    proposal_id = proposal_id(run.note.id)

    with true <- target == ReleaseNotes.message_anchor(proposal_id),
         {:ok, _proposal} <- proposal(run.id, run.note.id, person) do
      transition(operation, run, person, proposal_id)
    else
      _mismatch -> {:error, :stale_action}
    end
  end

  defp transition("approve_publish", run, person, proposal_id) do
    with :ok <- require_absent(revocation_id(proposal_id)),
         :ok <- require_review(run.status) do
      record_approval(run, person, proposal_id)
    end
  end

  defp transition("revoke_publish", run, person, proposal_id) do
    with :ok <- require_absent(approval_id(proposal_id)) do
      data = %{
        "type" => "publish_revocation",
        "run_id" => run.id,
        "proposal_id" => proposal_id,
        "version_id" => run.note.id,
        "approver" => person
      }

      Chat.send_message(
        Seeds.release_room_id(),
        "Revoked the publish proposal.",
        "user:" <> person,
        message_id: revocation_id(proposal_id),
        thread_id: run.id,
        reply_to_id: proposal_id,
        metadata: %{@event => data}
      )
    end
  end

  defp require_absent(id) do
    case ChatRuntime.get_room_history(Seeds.release_room_id(), id) do
      {:ok, nil} -> :ok
      {:ok, _record} -> {:error, :stale_action}
      {:error, _reason} = error -> error
    end
  end

  defp require_review(:reviewed), do: :ok
  defp require_review(_status), do: {:error, :review_required}

  defp record_approval(run, person, proposal_id) do
    id = approval_id(proposal_id)

    data = %{
      "type" => "publish_approval",
      "run_id" => run.id,
      "proposal_id" => proposal_id,
      "version_id" => run.note.id,
      "approver" => person
    }

    with {:ok, approval} <-
           Chat.send_message(
             Seeds.release_room_id(),
             "Approved the publish proposal.",
             "user:" <> person,
             message_id: id,
             thread_id: run.id,
             reply_to_id: proposal_id,
             metadata: %{@event => data}
           ) do
      case Workflow.advance(id) do
        {:ok, _receipt} = result -> result
        {:error, _reason} -> {:ok, approval}
      end
    end
  end

  def workflow_step(%{
        id: id,
        role: :user,
        actor: %{kind: :human, id: "user:" <> person},
        thread_id: root,
        reply_to_id: proposal_id,
        metadata: %{
          @event => %{
            "type" => "publish_approval",
            "run_id" => root,
            "proposal_id" => proposal_id,
            "version_id" => version_id,
            "approver" => person
          }
        }
      })
      when is_binary(root) and is_binary(proposal_id) and is_binary(version_id) do
    if id == approval_id(proposal_id) and proposal_id == proposal_id(version_id) do
      {:queue, %{type: :publish, id: id, root: root, version_id: version_id, person: person}}
    end
  end

  def workflow_step(%{
        id: id,
        role: :assistant,
        actor: %{id: @agent},
        thread_id: root,
        reply_to_id: approval_id,
        metadata: %{
          @event => %{"type" => type, "run_id" => root, "approval_id" => approval_id}
        }
      })
      when type in ["publish_receipt", "publish_uncertain"] and is_binary(approval_id) do
    if id == outcome_id(type, approval_id), do: {:complete, approval_id}
  end

  def workflow_step(_message), do: nil

  def execute(%{id: id} = step) do
    with {:ok, nil} <- saved_outcome(receipt_id(id)),
         {:ok, nil} <- saved_outcome(uncertainty_id(id)) do
      run_action(step)
    end
  end

  defp saved_outcome(id) do
    case ChatRuntime.get_room_history(Seeds.release_room_id(), id) do
      {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{}} -> Chat.get_message_view(id, @agent)
      other -> other
    end
  end

  defp run_action(%{id: id} = step) do
    case Jido.Exec.run(PublishReleaseNote, %{approval_id: id}, %{}, max_attempts: 1) do
      {:ok, receipt} ->
        record_outcome(step, "publish_receipt", "Published the approved release note.", receipt)

      {:error, %Jido.Error.ExecutionError{details: %{publication_uncertain: reason}}} ->
        record_outcome(step, "publish_uncertain", "Assembly could not confirm publication.", %{
          "reason" => Atom.to_string(reason)
        })

      {:error, _reason} = error ->
        error
    end
  end

  defp record_outcome(%{id: id, root: root, version_id: version_id}, type, body, fields) do
    data =
      Map.merge(fields, %{
        "type" => type,
        "run_id" => root,
        "approval_id" => id,
        "proposal_id" => proposal_id(version_id),
        "version_id" => version_id
      })

    Chat.send_message(Seeds.release_room_id(), body, @agent,
      message_id: outcome_id(type, id),
      thread_id: root,
      reply_to_id: id,
      role: :assistant,
      metadata: %{@event => data}
    )
  end

  defp outcome_id("publish_receipt", id), do: receipt_id(id)
  defp outcome_id("publish_uncertain", id), do: uncertainty_id(id)

  def approved_operation(id) do
    with {:ok, message} <- release_message(id),
         {:queue, %{id: ^id, root: root, version_id: version_id, person: person}} <-
           workflow_step(message),
         {:ok, ^person} <- ReleaseNotes.person_for("user:" <> person),
         :ok <- require_absent(revocation_id(proposal_id(version_id))),
         {:ok, %{"version" => version, "destination" => destination}} <-
           proposal(root, version_id, person),
         %{
           status: :reviewed,
           note: %{
             id: ^version_id,
             text: text,
             data: %{"version" => ^version, "assignee" => ^person}
           }
         } <-
           Enum.find(ReleaseNotes.runs(person), &(&1.id == root)) do
      {:ok, %{destination: destination, body: text, version_id: version_id}}
    else
      _unavailable -> {:error, :publication_approval_unavailable}
    end
  end

  defp proposal(root, version_id, person) do
    destination_id = Seeds.release_log_room_id()
    action = action()

    with {:ok,
          %{
            role: :assistant,
            actor: %{id: @agent},
            thread_id: ^root,
            reply_to_id: ^version_id,
            metadata: %{
              @event =>
                %{
                  "type" => "publish_proposal",
                  "run_id" => ^root,
                  "version_id" => ^version_id,
                  "action" => ^action,
                  "approver" => ^person,
                  "destination" => %{"id" => ^destination_id}
                } = proposal
            }
          }} <- release_message(proposal_id(version_id)) do
      {:ok, proposal}
    else
      _unavailable -> {:error, :publication_proposal_unavailable}
    end
  end

  defp release_message(id) do
    with {:ok, %Jido.Chat.Runtime.Room.HistoryRecord{} = record} <-
           ChatRuntime.get_room_history(Seeds.release_room_id(), id) do
      {:ok, Projections.message_from_fact(record.signal)}
    end
  end
end
