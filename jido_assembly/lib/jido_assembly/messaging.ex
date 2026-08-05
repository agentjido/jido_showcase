defmodule Jido.Assembly.Messaging do
  @moduledoc """
  Assembly's local `jido_messaging` instance.

  The Hologram UI treats this module as the canonical room/message store. The
  developer demo uses a small SQLite-backed persistence adapter so rooms,
  participants, messages, reactions, and lightweight threads survive restarts.
  """

  use Jido.Messaging,
    persistence: Jido.Messaging.Persistence.SQLite,
    persistence_opts: [path: "data/jido_assembly.sqlite3"],
    pubsub: Jido.Assembly.PubSub
end
