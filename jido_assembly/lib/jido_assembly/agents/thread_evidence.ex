defmodule Jido.Assembly.Agents.ThreadEvidence do
  @moduledoc "Returns bounded evidence from a release request and its replies."

  alias Jido.Assembly.Chat.Projections
  alias Jido.Assembly.ChatRuntime
  alias Jido.Chat.Message
  alias Jido.Chat.Runtime.Room.HistoryRecord

  def list(run, trigger) do
    with {:ok, replies} <-
           ChatRuntime.list_room_history(run.room_id,
             thread_id: run.thread_id,
             limit: 12,
             latest: true
           ) do
      evidence =
        replies
        |> Enum.map(&Projections.message_from_fact(&1.signal))
        |> Enum.filter(&(&1.role == :user))
        |> Enum.take(-5)

      request = Projections.message_from_fact(trigger.signal)
      {:ok, Enum.map([request | evidence], &view/1)}
    end
  end

  def fetch(scope, id) do
    with {:ok, %HistoryRecord{} = record} <- ChatRuntime.get_room_history(scope.room_id, id),
         true <-
           record.thread_id == scope.thread_id or
             (is_nil(record.thread_id) and id == scope.request_id),
         %Message{role: :user} = message <- Projections.message_from_fact(record.signal) do
      {:ok, view(message)}
    else
      _unavailable -> {:error, :release_evidence_unavailable}
    end
  end

  defp view(message) do
    %{
      "id" => message.id,
      "author" => message.actor.display_name || message.actor.id,
      "text" => String.byte_slice(Message.fallback_text(message), 0, 600)
    }
  end
end
