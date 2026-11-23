defmodule Jido.Assembly.Components.Assembly.BridgeDeliveries do
  use Hologram.Component

  prop :deliveries, :list

  def template do
    ~HOLO"""
    {%for delivery <- @deliveries}
      <p class="mt-1 text-xs text-[var(--assembly-chat-muted)]" title={delivery.external_room_id} role="status" aria-label={delivery.provider <> " delivery"}>
        {delivery.provider} · {delivery.status}
        {%if delivery.detail != ""}
          · {delivery.detail}
        {/if}
      </p>
    {/for}
    """
  end
end
