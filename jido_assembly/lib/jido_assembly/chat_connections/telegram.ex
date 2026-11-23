defmodule Jido.Assembly.ChatConnections.Telegram do
  @moduledoc "Managed Telegram provider account for the Assembly ops Room."

  use Jido.Agent,
    name: "assembly_telegram_connection",
    plugins: [Jido.Chat.Plugin, Jido.Chat.Runtime.Bridge]

  chat do
    connection :telegram do
      client(Jido.Chat.Telegram.Adapter, id: "assembly/telegram", credentials: %{})
      rooms([])
      commands([Jido.Chat.SendMessage, Jido.Chat.SendFile])

      source(Jido.Chat.Telegram.Source,
        emit: ["jido.chat.message.received", "jido.chat.reaction.*"]
      )
    end
  end

  routes do
    route("jido.chat.message.received", Jido.Assembly.ChatConnections.InboundMessage)
    route("jido.chat.reaction.*", Jido.Assembly.ChatConnections.InboundReaction)
    route("jido.chat.room.message", Jido.Assembly.ChatConnections.OutboundMessage)
    route("jido.chat.command.send_message", Jido.Chat.Plugin.Execute)
    route("jido.chat.command.send_message.completed", Jido.Chat.Runtime.Actions.BridgeResult)
    route("jido.chat.command.send_message.failed", Jido.Assembly.ChatConnections.DeliveryResult)
    route("jido.chat.command.send_file", Jido.Chat.Plugin.Execute)
    route("jido.chat.command.send_file.completed", Jido.Assembly.ChatConnections.DeliveryResult)
    route("jido.chat.command.send_file.failed", Jido.Assembly.ChatConnections.DeliveryResult)
  end
end
