defmodule Jido.Assembly.BridgesTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Bridges, Chat, ChatRuntime}

  setup do
    assert {:ok, _snapshot} =
             Bridges.ensure_ops_room!(Chat.default_room_id(),
               env_fun: env(%{}),
               listener_mode: :passive
             )

    on_exit(fn ->
      _ =
        Bridges.ensure_ops_room!(Chat.default_room_id(),
          env_fun: env(%{}),
          listener_mode: :passive
        )
    end)

    :ok
  end

  test "boot setup keeps durable provider declarations stopped in demo mode" do
    room_id = unique_room!()

    assert {:ok, snapshot} =
             Bridges.ensure_ops_room!(room_id, env_fun: env(%{}), listener_mode: :passive)

    assert snapshot.headline == "Demo connectors"
    assert snapshot.live_count == 0
    assert Enum.map(snapshot.connectors, & &1.mode) == ["demo", "demo"]
    assert snapshot.routing_policy.delivery_mode == "broadcast"

    for account_id <- Bridges.bridge_ids() do
      assert {:ok, declaration} = ChatRuntime.get_connection_declaration(account_id)
      assert declaration.desired == :stopped
      assert declaration.secret_refs["token"] in ["TELEGRAM_BOT_TOKEN", "DISCORD_BOT_TOKEN"]
      assert {:ok, bindings} = ChatRuntime.list_bridge_bindings(account_id)
      refute Enum.any?(bindings, & &1.enabled)
    end
  end

  test "boot setup creates V3 bindings from environment references without storing tokens" do
    room_id = unique_room!()

    vars = %{
      "TELEGRAM_BOT_TOKEN" => "telegram-token",
      "TELEGRAM_TEST_CHAT_ID" => "telegram-ops-room",
      "DISCORD_BOT_TOKEN" => "discord-token",
      "DISCORD_TEST_CHANNEL_ID" => "discord-ops-channel"
    }

    assert {:ok, snapshot} =
             Bridges.ensure_ops_room!(room_id,
               env_fun: env(vars),
               listener_mode: :passive
             )

    assert snapshot.headline == "Telegram + Discord live"
    assert snapshot.live_count == 2

    telegram = Enum.find(snapshot.connectors, &(&1.id == "telegram"))
    discord = Enum.find(snapshot.connectors, &(&1.id == "discord"))
    assert telegram.target_label == "telegram-ops-room"
    assert telegram.status == "configured"
    assert discord.target_label == "discord-ops-channel"
    assert discord.status == "configured"

    assert {:ok, telegram_declaration} =
             ChatRuntime.get_connection_declaration("assembly:telegram")

    assert telegram_declaration.definition_key == "assembly.telegram.v1"
    assert telegram_declaration.secret_refs == %{"token" => "TELEGRAM_BOT_TOKEN"}
    refute inspect(telegram_declaration) =~ "telegram-token"

    assert {:ok, telegram_binding} =
             ChatRuntime.get_bridge_binding("assembly:telegram", "telegram-ops-room")

    assert telegram_binding.room_id == room_id
    assert telegram_binding.direction == :both
    assert telegram_binding.enabled

    assert {:ok, discord_binding} =
             ChatRuntime.get_bridge_binding("assembly:discord", "discord-ops-channel")

    assert discord_binding.room_id == room_id
    assert discord_binding.direction == :both
    assert discord_binding.enabled
  end

  defp unique_room! do
    name = "bridge-test-#{System.unique_integer([:positive])}"

    assert {:ok, room, _messages, _signals} =
             Chat.create_channel_command(%{name: name, topic: "Bridge test room."})

    room.id
  end

  defp env(vars), do: fn key -> Map.get(vars, key) end
end
