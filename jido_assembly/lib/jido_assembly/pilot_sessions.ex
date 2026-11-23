defmodule Jido.Assembly.PilotSessions do
  @moduledoc "Tracks signed-in pilot sessions and closes their live streams on sign-out or expiry."
  use GenServer

  @lifetime_ms :timer.hours(12)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def open(session_id, user_id, lifetime_ms \\ @lifetime_ms) do
    GenServer.call(__MODULE__, {:open, session_id, user_id, lifetime_ms})
  end

  def valid?(session_id, user_id), do: GenServer.call(__MODULE__, {:valid?, session_id, user_id})

  def attach_stream(session_id, user_id) do
    GenServer.call(__MODULE__, {:attach_stream, session_id, user_id})
  end

  def revoke(nil), do: :ok
  def revoke(session_id), do: GenServer.call(__MODULE__, {:revoke, session_id})

  @impl true
  def init(sessions), do: {:ok, sessions}

  @impl true
  def handle_call({:open, id, user_id, lifetime_ms}, _from, sessions) do
    expire = System.monotonic_time(:millisecond) + lifetime_ms
    timer = Process.send_after(self(), {:expire, id, expire}, lifetime_ms)
    session = %{user_id: user_id, expires_at: expire, timer: timer, streams: %{}}
    {:reply, :ok, Map.put(close(sessions, id), id, session)}
  end

  def handle_call({:valid?, id, user_id}, _from, sessions) do
    {:reply, valid_session?(sessions[id], user_id), sessions}
  end

  def handle_call({:attach_stream, id, user_id}, {pid, _tag}, sessions) do
    if valid_session?(sessions[id], user_id) do
      ref = :erlang.monitor(:process, pid, [{:tag, {:stream_down, id}}])
      {:reply, true, put_in(sessions[id].streams[ref], pid)}
    else
      {:reply, false, sessions}
    end
  end

  def handle_call({:revoke, id}, _from, sessions), do: {:reply, :ok, close(sessions, id)}

  @impl true
  def handle_info({:expire, id, expires_at}, sessions) do
    case sessions do
      %{^id => %{expires_at: ^expires_at}} -> {:noreply, close(sessions, id)}
      _other -> {:noreply, sessions}
    end
  end

  def handle_info({{:stream_down, id}, ref, :process, _pid, _reason}, sessions) do
    case sessions do
      %{^id => %{streams: streams}} ->
        {:noreply, put_in(sessions[id].streams, Map.delete(streams, ref))}

      _other ->
        {:noreply, sessions}
    end
  end

  defp valid_session?(%{user_id: user_id, expires_at: expiry}, user_id),
    do: System.monotonic_time(:millisecond) < expiry

  defp valid_session?(_session, _user_id), do: false

  defp close(sessions, id) do
    case Map.pop(sessions, id) do
      {nil, remaining} ->
        remaining

      {%{timer: timer, streams: streams}, remaining} ->
        Process.cancel_timer(timer)

        Enum.each(streams, fn {ref, pid} ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
        end)

        remaining
    end
  end
end
