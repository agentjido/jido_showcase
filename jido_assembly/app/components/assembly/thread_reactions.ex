defmodule Jido.Assembly.Components.Assembly.ThreadReactions do
  use Hologram.Component

  alias Jido.Assembly.Components.Assembly.ReactionDelivery

  prop :message, :map

  def template do
    ~HOLO"""
    <div class="mt-1.5 flex flex-wrap items-center gap-1" aria-label="Message reactions">
      {%for reaction <- @message.reactions}
        <button
          class="inline-flex min-h-7 items-center gap-1 rounded-full border border-[var(--assembly-chat-line)] px-2 text-xs text-[var(--assembly-chat-text)] {if reaction.reacted do "bg-[var(--assembly-accent)]/25" else "bg-[var(--assembly-chat-pill)]" end}"
          type="button"
          aria-label={reaction.label}
          aria-pressed={if reaction.reacted do "true" else "false" end}
          $click={:set_reaction, message_id: @message.id, emoji: reaction.emoji, active: !reaction.reacted}
        >
          <span>{reaction.glyph}</span>
          <span>{reaction.count}</span>
        </button>
      {/for}
      {%for option <- @message.available_reactions}
        <button
          class="grid size-7 place-items-center rounded-full text-sm text-[var(--assembly-chat-muted)] hover:bg-[var(--assembly-chat-pill)]"
          type="button"
          aria-label={option.label}
          aria-pressed="false"
          title={option.label}
          $click={:set_reaction, message_id: @message.id, emoji: option.key, active: true}
        >{option.glyph}</button>
      {/for}
    </div>
    <ReactionDelivery destinations={Map.get(@message, :reaction_delivery, [])} />
    """
  end
end
