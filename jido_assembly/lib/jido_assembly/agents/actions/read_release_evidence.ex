defmodule Jido.Assembly.Agents.Actions.ReadReleaseEvidence do
  @moduledoc "Reads one permitted Jido Chat record for the current release request."

  alias Jido.Assembly.Agents.ThreadEvidence
  alias Jido.Assembly.ChatRuntime
  alias Jido.Assembly.ChatStorage
  alias Jido.Joi

  use Jido.Action,
    name: "read_release_evidence",
    description: "Read an evidence message from the current release thread by its ID.",
    schema:
      Joi.object(%{message_id: Joi.string(min_length: 1, max_length: 256)},
        unrecognized_keys: :error
      ),
    output_schema:
      Joi.object(%{"id" => Joi.string(), "author" => Joi.string(), "text" => Joi.string()})

  @impl true
  def run(%{message_id: id}, %{assembly_evidence_scope: scope}) do
    %{room_id: room, thread_id: thread, request_id: request} = scope

    with true <- id in scope.source_ids,
         {:ok, %{status: "running", room_id: ^room, thread_id: ^thread, trigger_id: ^request}} <-
           ChatStorage.get_agent_run(scope.run_id),
         {:ok, %{status: :active}} <-
           ChatRuntime.get_room_membership(room, "agent:triage") do
      ThreadEvidence.fetch(scope, id)
    else
      _unavailable -> {:error, :release_evidence_unavailable}
    end
  end

  def run(_params, _context), do: {:error, :release_evidence_unavailable}
end
