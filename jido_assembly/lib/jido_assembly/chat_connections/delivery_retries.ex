defmodule Jido.Assembly.ChatConnections.DeliveryRetries do
  @moduledoc """
  Wakes the Jido Chat bridge for durable, due delivery retries.

  SQLite retains the schedule until the new attempt is submitted. If this
  process stops after saving the attempt, the next poll can wake the bridge.
  """

  use GenServer

  alias Jido.Assembly.{ChatRuntime, ChatStorage}

  @poll_interval 250

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :dispatch)
    {:ok, nil}
  end

  @impl true
  def handle_info(:dispatch, state) do
    with {:ok, due} <- ChatStorage.due_delivery_retries() do
      accounts =
        for [id] <- due,
            {:ok, work} <- [ChatStorage.resume_delivery_retry(id)],
            into: MapSet.new(),
            do: work.account_id

      Enum.each(accounts, &ChatRuntime.recover_bridge/1)
    end

    Process.send_after(self(), :dispatch, @poll_interval)
    {:noreply, state}
  end
end
