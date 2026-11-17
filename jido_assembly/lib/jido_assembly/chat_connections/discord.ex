defmodule Jido.Assembly.ChatConnections.Discord do
  @moduledoc "Managed Discord provider account for the Assembly ops Room."

  use Jido.Agent,
    name: "assembly_discord_connection",
    plugins: [Jido.Chat.Plugin, Jido.Chat.Runtime.Bridge]

  chat do
    connection :discord do
      client(Jido.Chat.Discord.Adapter, id: "assembly/discord", credentials: %{})
      rooms([])
      commands([Jido.Chat.SendMessage])
      source(Jido.Chat.Discord.Source, emit: "jido.chat.message.received")
    end
  end

  routes do
    route("jido.chat.message.received", Jido.Chat.Runtime.Actions.BridgeInbound)
    route("jido.chat.room.message", Jido.Chat.Runtime.Actions.BridgeOutbound)
    route("jido.chat.command.send_message", Jido.Chat.Plugin.Execute)
    route("jido.chat.command.send_message.completed", Jido.Chat.Runtime.Actions.BridgeResult)
    route("jido.chat.command.send_message.failed", Jido.Chat.Runtime.Actions.BridgeResult)
  end
end
