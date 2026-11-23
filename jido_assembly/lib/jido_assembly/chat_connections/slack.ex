defmodule Jido.Assembly.ChatConnections.Slack do
  @moduledoc "Opt-in Slack provider account for Assembly."

  use Jido.Agent,
    name: "assembly_slack_connection",
    plugins: [Jido.Chat.Plugin, Jido.Chat.Runtime.Bridge]

  chat do
    connection :slack do
      client(Jido.Chat.Slack.Adapter, id: "assembly/slack", credentials: %{})
      rooms([])
      commands([Jido.Chat.SendMessage, Jido.Chat.SendFile])
      source(Jido.Chat.Slack.Source, emit: ["jido.chat.message.received", "jido.chat.reaction.*"])
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
