defmodule Jido.Assembly.LiveAcceptanceFormatter do
  @moduledoc false
  use GenServer

  @impl true
  def init(_options), do: {:ok, nil}

  @impl true
  def handle_cast({:test_finished, %{tags: %{assembly_live: true, scenario: id}} = test}, state) do
    report("LIVE #{id}", test.state)
    {:noreply, state}
  end

  def handle_cast(
        {:test_finished, %{tags: %{assembly_live: true, provider_probe: id}} = test},
        state
      ) do
    report("PROBE #{id}", test.state)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp report(_label, {:excluded, _}), do: :ok

  defp report(label, {:skipped, "Blocked: " <> reason}),
    do: IO.puts("#{label} blocked: #{reason}")

  defp report(label, {:skipped, _}), do: IO.puts("#{label} skipped")
  defp report(label, nil), do: IO.puts("#{label} passed")
  defp report(label, _state), do: IO.puts("#{label} failed")
end
