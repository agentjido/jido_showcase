defmodule Jido.Assembly.LiveProviderSetupTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{ChatRuntime, LiveProviderSetup}

  @profile %{
    secret_refs: %{"token" => "TELEGRAM_BOT_TOKEN"},
    target: "TELEGRAM_TEST_CHAT_ID",
    target_pattern: ~r/^-?[1-9]\d*$/
  }

  @tag scenario: "LV12"
  test "missing or invalid live setup reports blocked before the provider operation" do
    fixture = %{
      "TELEGRAM_TEST_CHAT_ID" => "10101",
      "TELEGRAM_BOT_TOKEN" => "test-placeholder",
      "TELEGRAM_BRIDGE_CHAT_ID" => "10102",
      "ASSEMBLY_LIVE_OPERATOR" => "1"
    }

    operation = fn target -> send(self(), {:operation_started, target}) end
    assert {:ok, original_declarations} = ChatRuntime.list_connection_declarations()

    for {setup, expected} <- [
          {Map.delete(fixture, "TELEGRAM_BOT_TOKEN"), "TELEGRAM_BOT_TOKEN is required"},
          {Map.delete(fixture, "TELEGRAM_TEST_CHAT_ID"),
           "TELEGRAM_TEST_CHAT_ID must identify a dedicated test target"},
          {Map.put(fixture, "TELEGRAM_TEST_CHAT_ID", "invalid"),
           "TELEGRAM_TEST_CHAT_ID must identify a dedicated test target"},
          {Map.delete(fixture, "ASSEMBLY_LIVE_OPERATOR"),
           "set ASSEMBLY_LIVE_OPERATOR=1 when an operator is ready"}
        ] do
      assert LiveProviderSetup.with_target(@profile, operation, &Map.get(setup, &1)) ==
               {:blocked, "Blocked: " <> expected}
    end

    refute_received {:operation_started, _}
    assert {:ok, ^original_declarations} = ChatRuntime.list_connection_declarations()

    LiveProviderSetup.with_target(@profile, operation, &Map.get(fixture, &1))
    assert_received {:operation_started, "10101"}
    refute_received {:operation_started, _}

    unattended = Map.put(@profile, :requires_operator, false)
    without_operator = Map.delete(fixture, "ASSEMBLY_LIVE_OPERATOR")
    LiveProviderSetup.with_target(unattended, operation, &Map.get(without_operator, &1))
    assert_received {:operation_started, "10101"}
  end
end
