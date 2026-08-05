defmodule Jido.Assembly.Presence do
  @moduledoc """
  Assembly's Phoenix Presence adapter.

  `Jido.Messaging.Presence` owns the reusable session bookkeeping, Phoenix
  Presence calls, TTL pruning, and normalized participant signals. Assembly only
  configures the adapter.
  """

  alias Jido.Assembly.Seeds

  use Jido.Messaging.Presence,
    messaging: Jido.Assembly.Messaging,
    presence: Jido.AssemblyWeb.Presence,
    topic: {__MODULE__, :presence_topic, []},
    source: "jido_assembly.presence",
    otp_app: :jido_assembly,
    signal_opts: [channel_type: :assembly, instance_id: "jido"],
    notify: {Jido.AssemblyWeb.PresenceNotifier, :notify, []}

  def presence_topic do
    "assembly:presence:#{Seeds.workspace_id()}"
  end
end
