defmodule Jido.AssemblyWeb.MessagingNotifier do
  @moduledoc """
  Mirrors externally committed messaging events into the Hologram workspace.

  Foreground page commands broadcast their own UI actions after writing through
  `Jido.Assembly.Chat`. Live bridge ingress commits messages through
  `Jido.Assembly.Messaging`, so this process listens for the canonical
  `jido.messaging.room.message_added` signal and emits the same page action.
  """

  use GenServer

  require Logger

  alias Hologram.Realtime
  alias Jido.Assembly.{Chat, Messaging}
  alias Jido.AssemblyWeb.SignalPresenter

  @subscription_path "jido.messaging.room.message_added"
  @retry_ms 250

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def message_saved_params(%Jido.Signal{} = signal) do
    with {:ok, message_id} <- signal_message_id(signal),
         {:ok, message} <- Chat.get_message_view(message_id) do
      {:ok,
       %{
         room_id: message.room_id,
         message: message,
         connector_snapshot: Chat.connector_snapshot(message.room_id),
         signal: SignalPresenter.summary(signal)
       }}
    end
  end

  def notify(%Jido.Signal{} = signal) do
    if hologram_started?() do
      case message_saved_params(signal) do
        {:ok, params} ->
          Realtime.broadcast_action({:workspace, Chat.workspace_id()}, :message_saved, params)

        {:error, :missing_message_id} ->
          Logger.debug("Assembly message notifier skipped signal without message_id")
          :ok

        {:error, :not_found} ->
          Logger.debug("Assembly message notifier skipped missing message")
          :ok

        {:error, reason} ->
          Logger.warning("Assembly message notifier failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    send(self(), :subscribe)
    {:ok, %{subscription_id: nil}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case Messaging.subscribe_signals(@subscription_path) do
      {:ok, subscription_id} ->
        {:noreply, %{state | subscription_id: subscription_id}}

      {:error, reason} ->
        Logger.debug("Assembly message notifier subscribe retry: #{inspect(reason)}")
        Process.send_after(self(), :subscribe, @retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{type: @subscription_path} = signal}, state) do
    notify(signal)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{subscription_id: subscription_id}) when is_binary(subscription_id) do
    Messaging.unsubscribe_signals(subscription_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp signal_message_id(signal) do
    case signal_value(signal, :message_id) || message_id_from_embedded_message(signal) do
      message_id when is_binary(message_id) and message_id != "" -> {:ok, message_id}
      _missing -> {:error, :missing_message_id}
    end
  end

  defp message_id_from_embedded_message(signal) do
    case signal_value(signal, :message) do
      %{id: id} -> id
      %{"id" => id} -> id
      _missing -> nil
    end
  end

  defp signal_value(%Jido.Signal{data: data}, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp signal_value(_signal, _key), do: nil

  defp hologram_started? do
    Process.whereis(Hologram.PubSub) != nil
  end
end
