defmodule Jido.Assembly.Components.Assembly.MessageAuthor do
  use Hologram.Component

  prop :message, :map

  def template do
    ~HOLO"""
    <h3 class="text-sm font-bold text-[var(--assembly-chat-text)]" aria-label={@message.author <> ", " <> @message.actor_role}>{@message.author}</h3>
    {%if @message.actor_role == "Agent"}<span class="assembly-agent-label" aria-hidden="true">Agent</span>{/if}
    """
  end
end
