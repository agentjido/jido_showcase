defmodule Jido.AssemblyWeb.RuntimeNotifier do
  @moduledoc """
  Projects committed Jido Chat Runtime facts into Hologram actions.

  The Runtime Bus is a notification layer. This process reads each canonical
  message from durable Assembly storage before it broadcasts a UI action.
  """

  use GenServer

  require Logger

  alias Hologram.Realtime
  alias Jido.Assembly.{Chat, ChatRuntime, ChatStorage}
  alias Jido.AssemblyWeb.SignalPresenter

  @message_type "jido.chat.room.message"
  @reaction_types ~w(jido.chat.reaction.added jido.chat.reaction.removed)
  @subscription_paths [@message_type, "jido.chat.reaction.*"]
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

  def reaction_saved_params(%Jido.Signal{type: type} = signal) when type in @reaction_types do
    with {:ok, message_id} <- signal_message_id(signal),
         {:ok, message} <- Chat.get_message_view(message_id) do
      {:ok,
       %{room_id: message.room_id, message: message, signal: SignalPresenter.summary(signal)}}
    end
  end

  def notify(%Jido.Signal{type: @message_type} = signal) do
    broadcast(:message_saved, fn -> message_saved_params(signal) end)

    case get_in(signal.data, ["message", "metadata"]) do
      %{"agent_prompt_message_id" => trigger_id} when is_binary(trigger_id) ->
        broadcast_message_update(:agent_run_saved, trigger_id)

      %{"assembly_release_note" => %{"type" => "cancelled", "run_id" => trigger_id}}
      when is_binary(trigger_id) ->
        broadcast_message_update(:agent_run_saved, trigger_id)

      _other ->
        :ok
    end
  end

  def notify(%Jido.Signal{type: type, data: %{"actor_id" => "provider:" <> _}} = signal)
      when type in @reaction_types,
      do: broadcast(:reaction_saved, fn -> reaction_saved_params(signal) end)

  def notify(%Jido.Signal{}), do: :ok

  defp broadcast(action, params_fun) do
    if hologram_started?() do
      case params_fun.() do
        {:ok, %{room_id: room_id} = params} ->
          case Chat.room_topic(room_id) do
            nil -> :ok
            topic -> Realtime.broadcast_action(topic, action, params)
          end

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
    :ok = ChatStorage.subscribe_deliveries()
    :ok = ChatStorage.subscribe_agent_runs()
    send(self(), :subscribe)
    {:ok, %{subscription_ids: [], bus_pid: nil, bus_ref: nil}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    with {:ok, bus_pid} <- ChatRuntime.runtime_bus(),
         {:ok, subscription_ids} <- subscribe_paths() do
      bus_ref = Process.monitor(bus_pid)

      {:noreply,
       %{state | subscription_ids: subscription_ids, bus_pid: bus_pid, bus_ref: bus_ref}}
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
  def handle_info({:signal, %Jido.Signal{} = signal}, state) do
    notify(signal)
    {:noreply, state}
  end

  def handle_info({:bridge_delivery_changed, message_id}, state) do
    broadcast_message_update(:bridge_delivery_saved, message_id)
    {:noreply, state}
  end

  def handle_info({:agent_run_changed, message_id}, state) do
    broadcast_message_update(:agent_run_saved, message_id)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp broadcast_message_update(action, message_id) do
    broadcast(action, fn ->
      with {:ok, message} <- Chat.get_message_view(message_id) do
        {:ok, %{room_id: message.room_id, message: message}}
      end
    end)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.subscription_ids, &ChatRuntime.unsubscribe_runtime/1)
    :ok
  end

  defp subscribe_paths do
    Enum.reduce_while(@subscription_paths, {:ok, []}, fn path, {:ok, ids} ->
      case ChatRuntime.subscribe_runtime(path) do
        {:ok, id} ->
          {:cont, {:ok, [id | ids]}}

        {:error, _reason} = error ->
          Enum.each(ids, &ChatRuntime.unsubscribe_runtime/1)
          {:halt, error}
      end
    end)
  end

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
    %{state | subscription_ids: [], bus_pid: nil, bus_ref: nil}
  end

  defp clear_subscription(state),
    do: %{state | subscription_ids: [], bus_pid: nil, bus_ref: nil}

  defp hologram_started?, do: Process.whereis(Hologram.PubSub) != nil
end
