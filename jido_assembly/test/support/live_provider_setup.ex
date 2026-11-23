defmodule Jido.Assembly.LiveProviderSetup do
  @moduledoc false

  def with_target(provider, operation, env \\ &System.get_env/1) do
    case blocker(provider, env) do
      false -> operation.(env.(provider.target))
      reason -> {:blocked, reason}
    end
  end

  def blocker(provider, env \\ &System.get_env/1) do
    missing =
      provider.secret_refs
      |> Map.values()
      |> Enum.sort()
      |> Enum.find(&(env.(&1) in [nil, ""]))

    cond do
      missing ->
        "Blocked: #{missing} is required"

      not Regex.match?(provider.target_pattern, env.(provider.target) || "") ->
        "Blocked: #{provider.target} must identify a dedicated test target"

      Map.get(provider, :requires_operator, true) and env.("ASSEMBLY_LIVE_OPERATOR") != "1" ->
        "Blocked: set ASSEMBLY_LIVE_OPERATOR=1 when an operator is ready"

      true ->
        false
    end
  end
end
