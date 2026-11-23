defmodule Jido.Assembly.Components.Assembly.ReleasePublication do
  use Hologram.Component

  prop :proposal, :map
  prop :status, :atom
  prop :viewer_id, :string

  def template do
    ~HOLO"""
    <section aria-label="Publish proposal" class="mt-2 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] p-3 text-sm">
      <h4 class="font-semibold">Publish proposal</h4>
      <dl class="mt-2 space-y-1 text-xs">
        <div><dt class="inline font-semibold">Destination</dt> <dd class="inline" data-assembly-destination-id={@proposal.destination_id}>{@proposal.destination_name}</dd></div>
        <div><dt class="inline font-semibold">Artifact</dt> <dd class="inline"><a class="underline underline-offset-2" href={@proposal.version_href}>Release note v{@proposal.version}</a></dd></div>
        <div><dt class="inline font-semibold">Approver</dt> <dd class="inline">{@proposal.approver}</dd></div>
        <div><dt class="inline font-semibold">Action</dt> <dd class="inline"><code>{@proposal.action}</code></dd></div>
      </dl>
      <p class="mt-2 text-xs text-[var(--assembly-chat-muted)]">{status_label(@status)}</p>
      {%if @proposal.approver_id == @viewer_id && @status in [:ready, :waiting]}
        <div class="mt-2 flex flex-wrap gap-2">
          {%if @status == :ready}
            <button type="button" class="rounded bg-[var(--assembly-accent)] px-2 py-1 font-semibold text-stone-950" $click={:approve_release_publication, target: "message-" <> @proposal.id}>
              Approve and publish
            </button>
          {/if}
          <button type="button" class="rounded border border-[var(--assembly-chat-line)] px-2 py-1 font-semibold" $click={:revoke_release_publication, target: "message-" <> @proposal.id}>
            Revoke proposal
          </button>
        </div>
      {/if}
    </section>
    """
  end

  defp status_label(:approved), do: "Publish approval recorded."
  defp status_label(:revoked), do: "Publish proposal revoked."
  defp status_label(:superseded), do: "A newer version replaced this proposal."
  defp status_label(:cancelled), do: "Release run cancelled."
  defp status_label(:uncertain), do: "Assembly could not confirm publication."
  defp status_label(_waiting), do: "Awaiting publish approval."
end
