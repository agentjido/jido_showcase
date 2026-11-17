defmodule Jido.Assembly.ChatConnections.EnvironmentResolver do
  @moduledoc "Resolves provider secrets from host environment references at activation time."

  @behaviour Jido.Chat.Runtime.SecretResolver

  @impl true
  def resolve(references, _context) do
    Enum.reduce_while(references, {:ok, %{}}, fn {name, environment_name}, {:ok, secrets} ->
      case System.get_env(environment_name) do
        value when is_binary(value) and value != "" ->
          {:cont, {:ok, Map.put(secrets, String.to_existing_atom(name), value)}}

        _value ->
          {:halt, {:error, :secret_missing}}
      end
    end)
  rescue
    ArgumentError -> {:error, :unknown_secret_name}
  end
end
