defmodule Jido.Assembly.MessagingTest do
  use ExUnit.Case, async: true

  alias Jido.Assembly.Messaging

  test "uses upstream jido_messaging SQLite persistence" do
    assert Messaging.__jido_messaging__(:persistence) == Jido.Messaging.Persistence.SQLite
    assert Messaging.__jido_messaging__(:persistence_opts) == [path: "data/jido_assembly.sqlite3"]
  end
end
