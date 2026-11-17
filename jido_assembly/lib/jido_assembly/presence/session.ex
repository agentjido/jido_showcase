defmodule Jido.Assembly.Presence.Session do
  @moduledoc false

  use GenServer

  alias Jido.AssemblyWeb.Presence, as: PhoenixPresence

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :session_id), start: {__MODULE__, :start_link, [opts]}}

  def update(pid, metadata), do: GenServer.call(pid, {:update, metadata})

  @impl true
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    user_id = Keyword.fetch!(opts, :user_id)
    metadata = Keyword.fetch!(opts, :metadata)

    case PhoenixPresence.track(self(), topic, user_id, metadata) do
      {:ok, _ref} -> {:ok, %{topic: topic, user_id: user_id, metadata: metadata}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:update, metadata}, _from, state) do
    case PhoenixPresence.update(self(), state.topic, state.user_id, metadata) do
      {:ok, _ref} -> {:reply, :ok, %{state | metadata: metadata}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
