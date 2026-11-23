defmodule Jido.Assembly.Components.Assembly.ReleaseArtifact do
  use Hologram.Component

  prop :artifact, :map
  prop :current, :boolean
  prop :publish_available, :boolean
  prop :superseded_by, :any
  prop :viewer_id, :string

  def template do
    ~HOLO"""
    <section aria-label="Release note" class="assembly-agent-card assembly-result" data-current={if @current do "true" else "false" end}>
      <div class="assembly-card-heading"><strong>Release note · v{@artifact.version}</strong>{%if @current}<small class="assembly-status">Ready for review</small>{/if}</div>
      <p class="assembly-note-body">{@artifact.body}</p>
      {%if @superseded_by}
        <p class="mt-2 text-xs text-[var(--assembly-chat-muted)]">
          Replaced by <a class="underline underline-offset-2" href={@superseded_by.href}>release note v{@superseded_by.version}</a>.
        </p>
      {/if}
      {%if @artifact.sources != []}
        <details class="mt-2 text-xs">
          <summary class="cursor-pointer text-[var(--assembly-chat-muted)]">Sources</summary>
          <ul class="mt-2 space-y-2">
            {%for source <- @artifact.sources}
              <li>
                <a class="font-semibold underline underline-offset-2" href={source.href}>{source.title}</a>
                <p class="mt-0.5 text-[var(--assembly-chat-muted)]">{source.evidence}</p>
              </li>
            {/for}
          </ul>
        </details>
      {/if}
      {%if @current}
        <p class="mt-2 text-xs text-[var(--assembly-chat-muted)]">Review assigned to {@artifact.name}.</p>
        {%if @artifact.assignee == @viewer_id}
          <button type="button" class="assembly-button assembly-primary mt-2" $click={:approve_release_artifact, target: "message-" <> @artifact.id}>
            Approve v{@artifact.version}
          </button>
          <details class="mt-2">
            <summary class="cursor-pointer font-semibold">Suggest edit</summary>
            <form class="mt-2 space-y-2" $submit="revise_release_artifact">
              <input type="hidden" name="target" value={"message-" <> @artifact.id} />
              <textarea name="revision" aria-label="Revised release note" class="block min-h-20 w-full rounded border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-input)] p-2" maxlength="2000" required>{@artifact.body}</textarea>
              <button type="submit" class="assembly-button assembly-primary">Send revision</button>
            </form>
          </details>
        {/if}
      {/if}
      {%if @publish_available && @artifact.assignee == @viewer_id}
        <button type="button" class="assembly-button mt-2" $click={:propose_release_publication, target: "message-" <> @artifact.id}>
          Prepare publish proposal
        </button>
      {/if}
    </section>
    """
  end
end
