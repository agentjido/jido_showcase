defmodule Jido.Assembly.Components.Assembly.Attachments do
  use Hologram.Component

  prop :files, :list

  def template do
    ~HOLO"""
    {%for file <- @files}
      <div class="mt-1 flex flex-wrap items-center gap-x-2 text-xs text-[var(--assembly-chat-muted)]">
        <span class="hero-paper-clip size-4" aria-hidden="true"></span>
        <span class="font-semibold">{file.filename}</span>
        <span>{file.media_type}</span>
        {%if file.size_bytes}
          <span>{file.size_bytes} bytes</span>
        {/if}
      </div>
    {/for}
    """
  end
end
