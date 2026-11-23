defmodule Jido.Assembly.Components.Assembly.MessageAvatar do
  use Hologram.Component

  prop :message, :map

  def template do
    ~HOLO"""
    <span class="assembly-avatar" data-role={@message.actor_role} data-sender={@message.sender_id} aria-hidden="true">{@message.avatar}</span>
    """
  end
end
