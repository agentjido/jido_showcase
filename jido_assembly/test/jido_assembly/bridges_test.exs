defmodule Jido.Assembly.BridgesTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.{Bridges, Chat, ChatRuntime}
  alias Jido.Chat, as: ChatSDK
  alias Jido.Chat.{Delivery, Plugin}
  alias Jido.Chat.Runtime.Connection

  defmodule RecordingTransport do
    @behaviour Jido.Chat.Discord.Transport
    @behaviour Jido.Chat.Telegram.Transport

    @impl Jido.Chat.Discord.Transport
    def call("fixture-token", :post, "/channels/200/messages", %{"content" => text}, _opts) do
      send(Jido.Assembly.BridgesTest, {:discord_send, text})
      {:ok, %{"id" => "201", "channel_id" => "200", "content" => text}}
    end

    @impl Jido.Chat.Telegram.Transport
    def call("fixture-token", "sendMessage", %{"chat_id" => "100", "text" => text}, _opts) do
      send(Jido.Assembly.BridgesTest, {:telegram_send, text})
      {:ok, %{"message_id" => 101, "chat" => %{"id" => 100}, "text" => text}}
    end
  end

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

  test "consolidated Telegram and Discord adapters relay both ways through an Assembly room" do
    Process.register(self(), __MODULE__)
    room_id = unique_room!()

    vars = %{
      "TELEGRAM_BOT_TOKEN" => "fixture-token",
      "TELEGRAM_TEST_CHAT_ID" => "100",
      "DISCORD_BOT_TOKEN" => "fixture-token",
      "DISCORD_TEST_CHANNEL_ID" => "200"
    }

    assert {:ok, _} =
             Bridges.ensure_ops_room!(room_id, env_fun: env(vars), listener_mode: :passive)

    {telegram, telegram_client} = start_fixture_connection!("assembly:telegram")
    {discord, discord_client} = start_fixture_connection!("assembly:discord")

    assert Application.get_application(telegram_client.adapter) == :jido_chat
    assert Application.get_application(discord_client.adapter) == :jido_chat

    ingest!(telegram, :telegram, telegram_client, %{
      "update_id" => 1,
      "message" => %{
        "message_id" => 102,
        "chat" => %{"id" => 100, "type" => "group"},
        "from" => %{"id" => 10, "first_name" => "Telegram sender"},
        "text" => "From Telegram"
      }
    })

    assert_receive {:discord_send, "From Telegram"}, 3_000

    ingest!(discord, :discord, discord_client, %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "202",
        "channel_id" => "200",
        "guild_id" => "20",
        "author" => %{"id" => "21", "username" => "Discord sender"},
        "content" => "From Discord"
      }
    })

    assert_receive {:telegram_send, "From Discord"}, 3_000
    refute_receive {:telegram_send, "From Telegram"}
    refute_receive {:discord_send, "From Discord"}

    bodies = Enum.map(Chat.list_message_views(room_id), & &1.body)
    assert "From Telegram" in bodies
    assert "From Discord" in bodies
  end

  defp start_fixture_connection!(account_id) do
    assert {:ok, declaration} = ChatRuntime.get_connection_declaration(account_id)
    assert {:ok, bindings} = ChatRuntime.list_bridge_bindings(account_id)
    assert {:ok, definition} = ChatRuntime.connection_definition(declaration.definition_key)
    declaration = %{declaration | secret_refs: %{}}

    assert {:ok, ref, agent} =
             Connection.prepare(ChatRuntime, account_id, definition,
               declaration: declaration,
               bindings: Enum.filter(bindings, & &1.enabled)
             )

    # Keep the Assembly routes and bindings. Replace provider I/O with the test transport.
    plugins =
      Enum.map(agent.plugins, fn
        %{provider: Plugin, data: %{connections: [connection]} = data} = plugin ->
          client = %{
            connection.client
            | credentials: %{token: "fixture-token"},
              transport: RecordingTransport
          }

          %{plugin | data: %{data | connections: [%{connection | client: client, source: nil}]}}

        plugin ->
          plugin
      end)

    assert {:ok, ^ref, server} =
             Connection.start_prepared(ChatRuntime, account_id, ref, %{agent | plugins: plugins})

    on_exit(fn -> ChatRuntime.stop_connection(account_id) end)
    assert [%{client: client}] = Plugin.connections(server)
    {server, client}
  end

  defp ingest!(server, name, client, input) do
    assert {:ok, %Delivery{signals: [signal]}} = ChatSDK.normalize(client, input)

    assert {:ok, %Jido.AgentServer.TurnResult{status: :committed}} =
             Plugin.ingest(server, name, signal)
  end

  defp unique_room! do
    name = "bridge-test-#{System.unique_integer([:positive])}"

    assert {:ok, room, _messages, _signals} =
             Chat.create_channel_command(%{name: name, topic: "Bridge test room."})

    room.id
  end

  defp env(vars), do: fn key -> Map.get(vars, key) end
end
