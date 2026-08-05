defmodule Jido.AssemblyWeb.Presence do
  @moduledoc """
  Phoenix Presence tracker for the Assembly demo workspace.

  Assembly keeps Phoenix-specific realtime process tracking here, outside
  `jido_messaging`, so the messaging package stays transport agnostic.
  """

  use Phoenix.Presence,
    otp_app: :jido_assembly,
    pubsub_server: Jido.Assembly.PubSub
end
