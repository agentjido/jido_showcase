defmodule Jido.Assembly.ChatConnections.X do
  @moduledoc "Opt-in X Direct Message provider account for Assembly."

  use Jido.Agent,
    name: "assembly_x_connection",
    plugins: [Jido.Chat.Plugin, Jido.Chat.Runtime.Bridge]

  chat do
    connection :x do
      client(Jido.Chat.X.Adapter, id: "assembly/x", credentials: %{})
      rooms([])
      commands([Jido.Chat.SendMessage])
    end
  end

  routes do
    route("jido.chat.message.received", Jido.Assembly.ChatConnections.InboundMessage)
    route("jido.chat.room.message", Jido.Assembly.ChatConnections.OutboundMessage)
    route("jido.chat.command.send_message", Jido.Chat.Plugin.Execute)
    route("jido.chat.command.send_message.completed", Jido.Chat.Runtime.Actions.BridgeResult)
    route("jido.chat.command.send_message.failed", Jido.Assembly.ChatConnections.DeliveryResult)
  end
end
