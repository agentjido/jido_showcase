defmodule Jido.Assembly.ChatRuntime do
  @moduledoc """
  Jido Chat V3 Runtime owned by Assembly.

  The Runtime uses the host Jido instance and the Assembly SQLite capability
  adapter. Starting the Jido Chat application does not start this tree.
  """

  use Jido.Chat.Runtime,
    jido: Jido.Assembly.Jido,
    storage: {Jido.Assembly.ChatStorage, Jido.Assembly.ChatStorage},
    room_definitions: %{
      "assembly.room.v1" => Module.concat(Jido.Assembly, ChatRoom)
    },
    connection_definitions: %{
      "assembly.telegram.v1" => Jido.Assembly.ChatConnections.Telegram,
      "assembly.discord.v1" => Jido.Assembly.ChatConnections.Discord
    },
    secret_resolver: Jido.Assembly.ChatConnections.EnvironmentResolver
end
