defmodule Jido.Assembly.BrowserAgent do
  @moduledoc false

  alias Jido.Assembly.ScriptedInference

  def configure!(gate, answer) do
    respond = fn _call ->
      wait_for_release(gate, answer, System.monotonic_time(:millisecond) + 20_000)
    end

    {:ok, supervisor} =
      Supervisor.start_link([{ScriptedInference, [respond, {:error, :provider_error}]}],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)

    Application.put_env(:jido_assembly, :agent_trigger_options,
      inference_client: ScriptedInference
    )
  end

  defp wait_for_release(gate, answer, deadline) do
    cond do
      File.exists?(gate) ->
        answer

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :browser_fixture_timeout}

      true ->
        Process.sleep(25)
        wait_for_release(gate, answer, deadline)
    end
  end
end
