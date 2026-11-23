defmodule Jido.Assembly.BrowserTelegram do
  @moduledoc false

  use GenServer

  alias Jido.Assembly.{Bridges, ChatRuntime, Seeds}
  alias Jido.Chat.{Delivery, Plugin}
  alias Jido.Chat.Runtime.Connection

  @behaviour Jido.Chat.Telegram.Transport
  @account "fixture:browser:telegram"
  @room "91320"
  @token "browser-fixture-token"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    :ok = Seeds.ensure_seeded!()

    {:ok, %{declaration: declaration}} =
      ChatRuntime.provision_connection("assembly.telegram.v1", %{
        account_id: @account,
        desired: :stopped
      })

    {:ok, binding} = Bridges.bind(@account, Seeds.release_room_id(), @room)
    {:ok, definition} = ChatRuntime.connection_definition(declaration.definition_key)

    {:ok, ref, agent} =
      Connection.prepare(ChatRuntime, @account, definition,
        declaration: %{declaration | secret_refs: %{}},
        bindings: [binding]
      )

    plugins =
      Enum.map(agent.plugins, fn
        %{provider: Plugin, data: %{connections: [connection]} = data} = plugin ->
          client = %{connection.client | credentials: %{token: @token}, transport: __MODULE__}
          %{plugin | data: %{data | connections: [%{connection | client: client, source: nil}]}}

        plugin ->
          plugin
      end)

    {:ok, ^ref, server} =
      Connection.start_prepared(ChatRuntime, @account, ref, %{agent | plugins: plugins})

    [%{client: client}] = Plugin.connections(server)
    {:ok, Map.merge(opts, %{server: server, client: client})}
  end

  @impl Jido.Chat.Telegram.Transport
  def call(
        @token,
        "sendMessage",
        %{"chat_id" => @room, "text" => "Telegram rejected this fixture message."},
        _opts
      ),
      do: {:error, {:rejected, :forbidden, %{}}}

  def call(
        @token,
        "sendMessage",
        %{"chat_id" => @room, "text" => "Telegram did not confirm this fixture message."},
        _opts
      ),
      do: {:error, {:unknown, :timeout, %{}}}

  def call(@token, "sendMessage", %{"chat_id" => @room, "text" => text}, _opts) do
    receipt = System.unique_integer([:positive, :monotonic])
    send(__MODULE__, {:sent, text, receipt})

    {:ok,
     %{"message_id" => receipt, "chat" => %{"id" => String.to_integer(@room)}, "text" => text}}
  end

  @impl GenServer
  def handle_info({:sent, request, receipt}, %{request: request} = state) do
    for index <- 1..state.reply_count do
      body = if state.reply_count == 1, do: state.evidence, else: "#{state.evidence} #{index}"
      ingest_reply!(state, receipt, 900_000 + index, body)
    end

    {:noreply, state}
  end

  def handle_info({:sent, _other, _receipt}, state), do: {:noreply, state}

  defp ingest_reply!(state, receipt, id, body) do
    reply = %{
      "update_id" => id,
      "message" => %{
        "message_id" => id,
        "chat" => %{"id" => String.to_integer(@room), "type" => "group"},
        "from" => %{"id" => 70_001, "first_name" => "Release QA"},
        "reply_to_message" => %{"message_id" => receipt},
        "text" => body
      }
    }

    {:ok, %Delivery{signals: [signal]}} = Jido.Chat.normalize(state.client, reply)

    {:ok, %Jido.AgentServer.TurnResult{status: :committed}} =
      Plugin.ingest(state.server, :telegram, signal)
  end
end
