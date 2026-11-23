defmodule Jido.Assembly.ReleaseNotes.Workflow do
  @moduledoc """
  Publishes scripted Triage responses for committed release requests.

  SQLite records each pending step with its input and removes it when its
  response commits. A stable response ID makes replay safe.
  """

  use GenServer

  alias Jido.Assembly.{ChatStorage, ReleaseNotes}

  @poll_ms 250

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def advance(input_id) do
    GenServer.call(__MODULE__, {:advance, input_id})
  catch
    :exit, _reason -> {:error, :release_workflow_unavailable}
  end

  @impl true
  def init(nil) do
    send(self(), :advance)
    {:ok, nil}
  end

  @impl true
  def handle_call({:advance, input_id}, _from, state), do: {:reply, run(input_id), state}

  @impl true
  def handle_info(:advance, state) do
    with {:ok, ids} <- ChatStorage.ready_release_steps() do
      Enum.each(ids, &run/1)
    end

    Process.send_after(self(), :advance, @poll_ms)
    {:noreply, state}
  end

  defp run(id) do
    case ReleaseNotes.run_step(id) do
      {:ok, _message} = result ->
        result

      {:error, _reason} = error ->
        _ = ChatStorage.defer_release_step(id)
        error
    end
  end
end
