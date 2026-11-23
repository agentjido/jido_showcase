defmodule Jido.Assembly.PilotStorageTest do
  use ExUnit.Case, async: true

  alias Jido.Assembly.ChatStorage

  @tag :tmp_dir
  test "a pilot database reopens with the same mode and rejects demo seeding", %{tmp_dir: dir} do
    path = Path.join(dir, "team.sqlite3")
    assert {:ok, first} = ChatStorage.start_link(name: nil, path: path, mode: :pilot)
    assert :ok = ChatStorage.put_metadata(first, "test", "retained")
    assert :ok = GenServer.stop(first)

    assert {:ok, second} = ChatStorage.start_link(name: nil, path: path, mode: :pilot)
    assert {:ok, "retained"} = ChatStorage.get_metadata(second, "test")
    assert :ok = GenServer.stop(second)
    assert {:error, :workspace_database_mode_mismatch} = start_store(path, :demo)
  end

  @tag :tmp_dir
  test "a demo database rejects pilot activation", %{tmp_dir: dir} do
    path = Path.join(dir, "demo.sqlite3")
    assert {:ok, pid} = ChatStorage.start_link(name: nil, path: path, mode: :demo)
    assert :ok = GenServer.stop(pid)
    assert {:error, :workspace_database_mode_mismatch} = start_store(path, :pilot)
  end

  defp start_store(path, mode) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)
      ChatStorage.start_link(name: nil, path: path, mode: mode)
    end)
    |> Task.await()
  end
end
