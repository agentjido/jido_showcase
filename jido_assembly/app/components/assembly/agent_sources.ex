defmodule Jido.Assembly.Components.Assembly.AgentSources do
  use Hologram.Component

  prop :sources, :list

  def template do
    ~HOLO"""
    {%if @sources != []}
      <ul class="mt-1 flex flex-wrap gap-x-3 text-xs" aria-label="Agent evidence">
        {%for source <- @sources}
          <li><a class="text-[var(--assembly-accent)] hover:underline focus-visible:underline" href={source.href} data-assembly-source-id={source.id}>Open evidence message</a></li>
        {/for}
      </ul>
    {/if}
    """
  end
end
