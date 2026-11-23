defmodule Jido.Assembly.Pilot do
  @moduledoc "Operator-managed team identities for a single Assembly workspace."

  @type account :: %{id: String.t(), name: String.t(), key_digest: binary()}
  @type roster :: %{String.t() => account()}

  @doc false
  def configure! do
    case Application.get_env(:jido_assembly, :pilot_roster) do
      nil ->
        if Application.get_env(:jido_assembly, :require_pilot, false) do
          raise "Set JIDO_ASSEMBLY_ROSTER and JIDO_ASSEMBLY_PILOT_DB to start Assembly in production."
        end

        Application.delete_env(:jido_assembly, :pilot_accounts)

      path ->
        with {:ok, contents} <- File.read(path),
             {:ok, accounts} <- parse_roster(contents) do
          Application.put_env(:jido_assembly, :pilot_accounts, accounts)
        else
          {:error, reason} ->
            raise "Could not load Assembly pilot roster (#{inspect(reason)})"
        end
    end
  end

  def enabled?, do: not is_nil(Application.get_env(:jido_assembly, :pilot_accounts))
  def mode, do: if(enabled?(), do: :pilot, else: :demo)

  def agents_enabled? do
    :jido_assembly
    |> Application.get_env(:agent_trigger_options, [])
    |> Keyword.get(:enabled, not enabled?())
  end

  def people do
    accounts()
    |> Map.values()
    |> Enum.map(&Map.take(&1, [:id, :name]))
    |> Enum.sort_by(&{&1.name, &1.id})
  end

  @spec parse_roster(binary()) :: {:ok, roster()} | {:error, atom()}
  def parse_roster(contents) do
    case Jason.decode(contents) do
      {:ok, [_ | _] = entries} when length(entries) <= 50 -> parse_accounts(entries)
      _other -> {:error, :invalid_roster}
    end
  end

  @spec authenticate(term(), term(), roster()) :: {:ok, String.t()} | :error
  def authenticate(id, key, roster \\ accounts())

  def authenticate(id, key, roster)
      when is_binary(id) and byte_size(id) <= 45 and is_binary(key) and byte_size(key) == 43 do
    account = Map.get(roster, id)
    digest = if account, do: account.key_digest, else: <<0::256>>

    if Plug.Crypto.secure_compare(:crypto.hash(:sha256, key), digest) and account do
      {:ok, id}
    else
      :error
    end
  end

  def authenticate(_id, _key, _roster), do: :error

  defp accounts, do: Application.get_env(:jido_assembly, :pilot_accounts, %{})

  defp parse_accounts(entries) do
    entries
    |> Enum.reduce_while({%{}, MapSet.new()}, &parse_account/2)
    |> case do
      {accounts, %MapSet{}} -> {:ok, accounts}
      {:error, _reason} = error -> error
    end
  end

  defp parse_account(%{"id" => id, "name" => name, "key_sha256" => hex}, {accounts, used})
       when is_binary(id) and is_binary(name) and is_binary(hex) do
    name = String.trim(name)

    with true <- Regex.match?(~r/\Auser:[a-z][a-z0-9_-]{0,39}\z/, id),
         false <- id in ["user:you", "user:triage", "user:bridge", "user:runbook"],
         true <- byte_size(name) in 1..100 and not Regex.match?(~r/[[:cntrl:]]/u, name),
         {:ok, <<_::256>> = digest} <- Base.decode16(hex, case: :mixed) do
      cond do
        Map.has_key?(accounts, id) ->
          {:halt, {:error, :duplicate_id}}

        MapSet.member?(used, digest) ->
          {:halt, {:error, :duplicate_key}}

        true ->
          account = %{id: id, name: name, key_digest: digest}
          {:cont, {Map.put(accounts, id, account), MapSet.put(used, digest)}}
      end
    else
      _other -> {:halt, {:error, :invalid_account}}
    end
  end

  defp parse_account(_entry, _acc), do: {:halt, {:error, :invalid_account}}
end
