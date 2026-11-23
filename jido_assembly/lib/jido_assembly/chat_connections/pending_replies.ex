defmodule Jido.Assembly.ChatConnections.PendingReplies do
  @moduledoc """
  Replays provider replies once their exact parent and thread links exist.

  SQLite holds the normalized signal. The active named connection validates
  the signal again on replay. The bridge stores inbound work before it
  acknowledges the turn, so replay after a crash uses the same work ID.
  """

  use GenServer

  alias Jido.Assembly.{ChatRuntime, ChatStorage}
  alias Jido.Chat.Plugin

  @poll_interval 250

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :dispatch)
    {:ok, nil}
  end

  @impl true
  def handle_info(:dispatch, state) do
    case ChatStorage.ready_bridge_replies() do
      {:ok, replies} ->
        Enum.each(replies, fn reply ->
          outcome = dispatch(reply)
          ChatStorage.settle_bridge_reply(reply, outcome)
        end)

      {:error, _reason} ->
        :ok
    end

    Process.send_after(self(), :dispatch, @poll_interval)
    {:noreply, state}
  end

  defp dispatch(reply) do
    with {:ok, ref} <- ChatRuntime.connection_ref(reply.account_id),
         {:ok, server} <- Jido.resolve_agent(ChatRuntime.jido(), ref),
         %{name: name} <-
           Enum.find(Plugin.connections(server), &(Atom.to_string(&1.name) == reply.connection)),
         {:ok, %Jido.AgentServer.TurnResult{status: :committed}} <-
           Plugin.ingest(server, name, reply.signal) do
      :dispatched
    else
      _result -> :retry
    end
  catch
    :exit, _reason -> :retry
  end
end
