defmodule Jido.AssemblyWeb.PresenceNotifier do
  @moduledoc """
  Mirrors background presence changes into the Hologram workspace channel.

  Page commands broadcast their own foreground presence touches. This notifier
  handles presence changes that originate outside a page command, such as
  explicit leave calls and TTL pruning.
  """

  alias Hologram.Realtime
  alias Jido.Assembly.Seeds
  alias Jido.AssemblyWeb.SignalPresenter

  @signal_priority [
    "jido.messaging.participant.presence_changed",
    "jido.messaging.room.participant_left",
    "jido.messaging.room.participant_joined"
  ]

  def notify(_event, presence, signals) do
    if hologram_started?() do
      Realtime.broadcast_action({:workspace, Seeds.workspace_id()}, :presence_changed, %{
        presence: presence,
        signal: signal_summary(signals)
      })
    else
      :ok
    end
  end

  defp signal_summary(signals) do
    SignalPresenter.summary(signals, @signal_priority)
  end

  defp hologram_started? do
    Process.whereis(Hologram.PubSub) != nil
  end
end
