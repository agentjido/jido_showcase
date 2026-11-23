defmodule Jido.Assembly.Components.Assembly.ReactionDelivery do
  use Hologram.Component

  prop :destinations, :list

  def template do
    ~HOLO"""
    {%for destination <- @destinations}
      <p class="mt-1 text-xs text-[var(--assembly-chat-muted)]" role="status">
        Reaction saved here. Delivery to {String.upcase(destination.provider)} is unsupported.
      </p>
    {/for}
    """
  end
end
