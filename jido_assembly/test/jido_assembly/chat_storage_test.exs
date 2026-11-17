defmodule Jido.Assembly.ChatStorageTest do
  use ExUnit.Case, async: false

  alias Jido.Assembly.ChatStorage

  test "uses the host SQLite adapter for Jido Chat Runtime data" do
    key = "test/storage/#{System.unique_integer([:positive])}"

    assert :ok = ChatStorage.put_metadata(key, "durable")
    assert {:ok, "durable"} = ChatStorage.get_metadata(key)

    capabilities = ChatStorage.__storage_capabilities__()
    assert Jido.Chat.Runtime.Storage.Rooms in capabilities
    assert Jido.Chat.Runtime.Storage.History in capabilities
    assert Jido.Chat.Runtime.Storage.Connections in capabilities
    assert Jido.Chat.Runtime.Storage.Bindings in capabilities
  end
end
