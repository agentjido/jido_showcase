defmodule Jido.AssemblyWeb.RuntimeNotifier do
  @moduledoc """
  Projects committed Jido Chat Runtime facts into Hologram actions.

  The Runtime Bus is a notification layer. This process reads each canonical
  message from durable Assembly storage before it broadcasts a UI action.
  """

  use GenServer

  require Logger

  alias Hologram.Realtime
  alias Jido.Assembly.{Chat, ChatRuntime}
  alias Jido.AssemblyWeb.SignalPresenter

  @subscription_path "jido.chat.room.message"
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

        {:error, reason} when reason in [:missing_message_id, :not_found] ->
          Logger.debug("Assembly Runtime notifier skipped a missing message: #{inspect(reason)}")
          :ok

        {:error, reason} ->
          Logger.warning("Assembly Runtime notifier failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    send(self(), :subscribe)
    {:ok, %{subscription_id: nil, bus_pid: nil, bus_ref: nil}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    with {:ok, bus_pid} <- ChatRuntime.runtime_bus(),
         {:ok, subscription_id} <- ChatRuntime.subscribe_runtime(@subscription_path) do
      bus_ref = Process.monitor(bus_pid)
      {:noreply, %{state | subscription_id: subscription_id, bus_pid: bus_pid, bus_ref: bus_ref}}
    else
      {:error, reason} ->
        Logger.debug("Assembly Runtime notifier subscribe retry: #{inspect(reason)}")
        Process.send_after(self(), :subscribe, @retry_ms)
        {:noreply, clear_subscription(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{bus_ref: ref, bus_pid: pid} = state) do
    Process.send_after(self(), :subscribe, @retry_ms)
    {:noreply, clear_subscription(state)}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{type: @subscription_path} = signal}, state) do
    notify(signal)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{subscription_id: subscription_id}) when is_binary(subscription_id) do
    ChatRuntime.unsubscribe_runtime(subscription_id)
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

  defp clear_subscription(%{bus_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | subscription_id: nil, bus_pid: nil, bus_ref: nil}
  end

  defp clear_subscription(state),
    do: %{state | subscription_id: nil, bus_pid: nil, bus_ref: nil}

  defp hologram_started?, do: Process.whereis(Hologram.PubSub) != nil
end
