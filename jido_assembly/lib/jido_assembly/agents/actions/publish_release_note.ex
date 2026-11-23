defmodule Jido.Assembly.Agents.Actions.PublishReleaseNote do
  @moduledoc "Posts the exact release note authorized by a committed human approval."

  alias Jido.Assembly.{Chat, ChatRuntime}
  alias Jido.Assembly.Chat.Projections
  alias Jido.Assembly.ReleaseNotes.Publication
  alias Jido.Chat.Message
  alias Jido.Error
  alias Jido.Joi

  use Jido.Action,
    name: "publish_release_note",
    description: "Post the version from a committed release approval to its named destination.",
    schema: Joi.object(%{approval_id: Joi.string(min_length: 1)}, unrecognized_keys: :error),
    output_schema:
      Joi.object(%{"destination_id" => Joi.string(), "destination_message_id" => Joi.string()})

  @agent "agent:triage"
  @event "assembly_release_note"

  @impl true
  def run(%{approval_id: approval_id}, _context) do
    with {:ok, %{destination: %{"id" => room_id}, body: body, version_id: version_id}} <-
           Publication.approved_operation(approval_id),
         id = Publication.destination_message_id(approval_id),
         data = %{"type" => "published", "approval_id" => approval_id, "version_id" => version_id},
         :ok <- publish(room_id, id, body, data) do
      {:ok, %{"destination_id" => room_id, "destination_message_id" => id}}
    end
  end

  defp publish(room_id, id, body, data) do
    case ChatRuntime.get_room_history(room_id, id) do
      {:ok, nil} ->
        case Chat.send_message(room_id, body, @agent,
               message_id: id,
               role: :assistant,
               metadata: %{@event => data}
             ) do
          {:ok, _message} -> :ok
          {:error, _reason} = error -> error
        end

      {:ok, record} ->
        case Projections.message_from_fact(record.signal) do
          %Message{role: :assistant, actor: %{id: @agent}, metadata: %{@event => ^data}} = message ->
            if Message.fallback_text(message) == body,
              do: :ok,
              else: uncertain(:destination_conflict)

          _other ->
            uncertain(:destination_conflict)
        end

      {:error, _reason} ->
        uncertain(:destination_unavailable)
    end
  end

  defp uncertain(reason) do
    {:error,
     Error.execution_error("Could not confirm the publication outcome.", %{
       publication_uncertain: reason
     })}
  end
end
