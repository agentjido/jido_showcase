defmodule Jido.Assembly.Components.Assembly.MessageBody do
  use Hologram.Component

  prop :message, :map

  def template do
    ~HOLO"""
    <div class="mt-1 max-w-[74ch] whitespace-pre-wrap break-words text-sm leading-6 text-[var(--assembly-chat-text)]"
    >{%for part <- Map.get(@message, :formatted_parts, [%{kind: :text, text: @message.body}])}{%if part.kind == :text}{part.text}{/if}{%if part.kind == :link}<a
      class="underline decoration-[var(--assembly-chat-muted)] underline-offset-2"
      href={part.text}
      target="_blank"
      rel="noopener noreferrer"
    >{part.text}</a>{/if}{%if part.kind == :code}<code
      class="rounded bg-[var(--assembly-chat-raised)] px-1"
    >{part.text}</code>{/if}{%if part.kind == :code_block}<code
      class="block overflow-x-auto rounded border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] px-2 py-1"
    >{part.text}</code>{/if}{/for}</div>
    """
  end
end
