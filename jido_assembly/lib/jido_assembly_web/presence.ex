defmodule Jido.AssemblyWeb.Presence do
  @moduledoc """
  Phoenix Presence tracker for the Assembly demo workspace.

  Assembly keeps Phoenix-specific realtime process tracking here, outside
  Jido Chat Runtime, so online state stays separate from durable Room membership.
  """

  use Phoenix.Presence,
    otp_app: :jido_assembly,
    pubsub_server: Jido.Assembly.PubSub
end
