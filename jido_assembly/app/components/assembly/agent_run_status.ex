defmodule Jido.Assembly.Components.Assembly.AgentRunStatus do
  use Hologram.Component

  prop :runs, :list

  def template do
    ~HOLO"""
    {%for run <- @runs}
      <p class="mt-1 text-xs text-[var(--assembly-chat-muted)]" role="status" aria-label={run.label}>
        {run.label} · {run.status}
      </p>
    {/for}
    """
  end
end
