defmodule Jido.Assembly.PilotTest do
  use ExUnit.Case, async: true

  alias Jido.Assembly.Pilot

  @key Base.url_encode64(<<1::256>>, padding: false)
  @digest Base.encode16(:crypto.hash(:sha256, @key))
  @account %{"id" => "user:ada", "name" => "Ada Turner", "key_sha256" => @digest}

  test "loads a named account with a decoded digest" do
    assert {:ok, %{"user:ada" => %{name: "Ada Turner", key_digest: <<_::256>>}}} =
             parse([@account])
  end

  test "requires stable human IDs and a display name" do
    for id <- ["ada", "agent:ada", "user:Ada", "user:you", "user:bad/name"] do
      assert {:error, :invalid_account} = parse([%{@account | "id" => id}])
    end

    assert {:error, :invalid_account} = parse([%{@account | "name" => " "}])
  end

  test "rejects duplicate IDs and digests" do
    assert {:error, :duplicate_id} = parse([@account, @account])
    assert {:error, :duplicate_key} = parse([@account, %{@account | "id" => "user:eli"}])
  end

  test "requires a digest and rejects invalid or empty rosters" do
    assert {:error, :invalid_account} = parse([%{@account | "key_sha256" => @key}])
    assert {:error, :invalid_roster} = parse([])
    assert {:error, :invalid_roster} = Pilot.parse_roster("{")
  end

  test "authenticates only the account that matches a correctly sized key" do
    assert {:ok, roster} = parse([@account])
    assert {:ok, "user:ada"} = Pilot.authenticate("user:ada", @key, roster)
    assert :error = Pilot.authenticate("user:eli", @key, roster)
    assert :error = Pilot.authenticate("user:ada", String.duplicate("X", 43), roster)
    assert :error = Pilot.authenticate("user:ada", String.duplicate("x", 200), roster)
    assert :error = Pilot.authenticate("user:ada", %{}, roster)
  end

  defp parse(accounts), do: accounts |> Jason.encode!() |> Pilot.parse_roster()
end
