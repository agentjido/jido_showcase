defmodule Jido.Assembly.PilotSessionsTest do
  use ExUnit.Case, async: true

  alias Jido.Assembly.PilotSessions

  test "a session is valid only for its own user and until revoked" do
    id = make_ref()
    assert :ok = PilotSessions.open(id, "user:ada")
    assert PilotSessions.valid?(id, "user:ada")
    refute PilotSessions.valid?(id, "user:lee")
    refute PilotSessions.valid?(make_ref(), "user:ada")
    assert :ok = PilotSessions.revoke(id)
    refute PilotSessions.valid?(id, "user:ada")
    refute PilotSessions.attach_stream(id, "user:ada")
  end

  test "sign-out stops only the streams for that session" do
    first = make_ref()
    second = make_ref()
    :ok = PilotSessions.open(first, "user:ada")
    :ok = PilotSessions.open(second, "user:ada")
    {_pid, first_ref} = open_stream(first)
    {second_pid, second_ref} = open_stream(second)

    assert :ok = PilotSessions.revoke(first)
    assert_receive {:DOWN, ^first_ref, :process, _, :killed}
    assert Process.alive?(second_pid)
    assert PilotSessions.valid?(second, "user:ada")
    assert :ok = PilotSessions.revoke(second)
    assert_receive {:DOWN, ^second_ref, :process, _, :killed}
  end

  test "expiry closes an attached stream and blocks later requests" do
    id = make_ref()
    assert :ok = PilotSessions.open(id, "user:ada", 200)
    {_pid, ref} = open_stream(id)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000
    refute PilotSessions.valid?(id, "user:ada")
  end

  defp open_stream(id) do
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(test, {:attached, self(), PilotSessions.attach_stream(id, "user:ada")})
        Process.sleep(:infinity)
      end)

    assert_receive {:attached, ^pid, true}
    {pid, ref}
  end
end
