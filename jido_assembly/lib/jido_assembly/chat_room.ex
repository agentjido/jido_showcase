defmodule Jido.Assembly.ChatRoom do
  @moduledoc "Assembly Room Agent definition for channels, direct messages, and threads."

  use Jido.Chat.Runtime.Room, name: "jido_assembly_room"

  room do
    admin("user:you")
    runtime(Module.concat(Jido.Assembly, ChatRuntime))
    history_limit(500)
    member_limit(200)
  end
end
