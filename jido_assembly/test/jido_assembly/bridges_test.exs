defmodule Jido.Assembly.BridgesTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Bridges, Chat, Messaging}

  setup do
    reset_connector_configs()

    on_exit(fn ->
      reset_connector_configs()
    end)

    :ok
  end

  test "boot setup keeps connectors in demo mode when credentials are absent" do
    room_id = unique_room!()

    assert {:ok, snapshot} =
             Bridges.ensure_ops_room!(room_id, env_fun: env(%{}), reconcile?: false)

    assert snapshot.headline == "Demo connectors"
    assert snapshot.live_count == 0
    assert Enum.map(snapshot.connectors, & &1.mode) == ["demo", "demo"]

    assert {:ok, policy} = Messaging.get_routing_policy(room_id)
    assert policy.delivery_mode == :broadcast
    assert policy.failover_policy == :broadcast
    assert policy.fallback_order == Bridges.bridge_ids()

    assert {:ok, []} = Messaging.list_room_bindings(room_id)
    assert {:ok, []} = Messaging.resolve_outbound_routes(room_id)
    assert Bridges.delivery_metadata(:no_routes)["route_decision"] == "no_routes"
  end

  test "boot setup creates live bridge configs, bindings, and broadcast routing from env" do
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
               listener_mode: :passive,
               reconcile?: false
             )

    assert snapshot.headline == "Telegram + Discord live"
    assert snapshot.live_count == 2

    telegram = Enum.find(snapshot.connectors, &(&1.id == "telegram"))
    discord = Enum.find(snapshot.connectors, &(&1.id == "discord"))

    assert telegram.mode == "live"
    assert telegram.target_label == "telegram-ops-room"
    assert discord.mode == "live"
    assert discord.target_label == "discord-ops-channel"

    assert {:ok, telegram_config} = Messaging.get_bridge_config("assembly:telegram")
    assert telegram_config.enabled
    assert telegram_config.adapter_module == Jido.Chat.Telegram.Adapter
    assert telegram_config.opts["target"] == "telegram-ops-room"

    assert {:ok, discord_config} = Messaging.get_bridge_config("assembly:discord")
    assert discord_config.enabled
    assert discord_config.adapter_module == Jido.Chat.Discord.Adapter
    assert discord_config.opts["target"] == "discord-ops-channel"

    assert {:ok, bindings} = Messaging.list_room_bindings(room_id)
    assert Enum.count(bindings) == 2

    assert Enum.any?(
             bindings,
             &(&1.channel == :telegram and &1.bridge_id == "assembly:telegram" and
                 &1.external_room_id == "telegram-ops-room" and &1.direction == :both)
           )

    assert Enum.any?(
             bindings,
             &(&1.channel == :discord and &1.bridge_id == "assembly:discord" and
                 &1.external_room_id == "discord-ops-channel" and &1.direction == :both)
           )

    assert {:ok, routes} = Messaging.resolve_outbound_routes(room_id)
    assert Enum.map(routes, & &1.bridge_id) == Bridges.bridge_ids()
    assert Enum.map(routes, & &1.external_room_id) == ["telegram-ops-room", "discord-ops-channel"]
  end

  defp unique_room! do
    name = "bridge-test-#{System.unique_integer([:positive])}"

    assert {:ok, room, _messages, _signals} =
             Chat.create_channel_command(%{name: name, topic: "Bridge test room."})

    room.id
  end

  defp env(vars), do: fn key -> Map.get(vars, key) end

  defp reset_connector_configs do
    Enum.each(Bridges.bridge_ids(), fn bridge_id ->
      _ = Messaging.delete_bridge_config(bridge_id)
    end)

    _ = Bridges.ensure_ops_room!(Chat.default_room_id(), env_fun: env(%{}), reconcile?: false)
    :ok
  end
end
