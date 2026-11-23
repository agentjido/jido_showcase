defmodule Jido.Assembly.Components.Assembly.ReleaseDecision do
  use Hologram.Component

  alias Jido.Assembly.Components.Assembly.MessageBody

  prop :decision, :any
  prop :message, :map
  prop :pending, :boolean
  prop :viewer_id, :string

  def template do
    ~HOLO"""
    {%if @decision}
      <section aria-label="Release decision" class="assembly-agent-card assembly-decision" data-pending={if @pending do "true" else "false" end}>
        <div class="assembly-card-heading"><strong>Decision requested</strong><span>{if @pending do "Assigned to " <> @decision.name else "Closed" end}</span></div>
        <MessageBody message={@message} />
        {%if @pending && @decision.assignee == @viewer_id}
          <div class="mt-2 flex flex-wrap gap-2">
            {%for {choice, label} <- @decision.choices}
              <button type="button" class="assembly-button" $click={:answer_release_decision, target: @decision.id, choice: choice}>
                {label}
              </button>
            {/for}
          </div>
        {%else}
          <ul class="mt-1 list-disc space-y-1 pl-5 text-[var(--assembly-chat-muted)]">
            {%for {_key, label} <- @decision.choices}
              <li>{label}</li>
            {/for}
          </ul>
        {/if}
      </section>
    {/if}
    """
  end
end
