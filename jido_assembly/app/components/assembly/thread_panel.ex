defmodule Jido.Assembly.Components.Assembly.ThreadPanel do
  use Hologram.Component

  alias Jido.Assembly.Components.Assembly.{
    AgentRunStatus,
    AgentSources,
    Attachments,
    BridgeDeliveries,
    MessageAuthor,
    MessageAvatar,
    MessageBody,
    ReleaseArtifact,
    ReleaseDecision,
    ReleasePublication,
    ThreadReactions
  }

  prop :current_user, :map
  prop :focused_message_id, :any
  prop :reply_draft, :string
  prop :reply_error, :any
  prop :reply_pending, :boolean
  prop :release_error, :any
  prop :thread_messages, :list
  prop :mobile, :boolean
  prop :thread_root, :any

  def template do
    ~HOLO"""
    <aside class={if @mobile do "assembly-thread-mobile" else "assembly-thread-inline" end} role={if @mobile do "dialog" else "complementary" end} aria-label="Thread" data-assembly-thread-root={@thread_root.id} $key_down.escape="close_thread">
      <header class="assembly-thread-head">
        <h2>{if release_request?(@thread_root) do "Triage thread" else "Thread" end}</h2>
        <button type="button" class="assembly-icon-button" aria-label="Close thread" title="Close thread" data-assembly-thread-close $click="close_thread">
          <span class="hero-x-mark size-4"></span>
        </button>
      </header>
      <div class="assembly-thread-messages" data-assembly-thread-scroll>
        {%if @mobile}
          <article class="assembly-message">
            <MessageAvatar message={@thread_root} />
            <div class="min-w-0">
              <div class="assembly-message-heading">
                <MessageAuthor message={@thread_root} />
                <a href={@thread_root.permalink} class="assembly-time" aria-label="Link to message"><time>{@thread_root.time}</time></a>
              </div>
              <MessageBody message={@thread_root} />
              <Attachments files={Map.get(@thread_root, :attachments, [])} />
              <AgentRunStatus runs={Map.get(@thread_root, :agent_runs, [])} />
              <BridgeDeliveries deliveries={Map.get(@thread_root, :bridge_deliveries, [])} />
            </div>
          </article>
        {/if}
        <div class="assembly-thread-actions">
          <ThreadReactions message={@thread_root} />
          {%if release_cancel_available?(@thread_root, @current_user.id, @thread_messages)}
            <button type="button" class="assembly-button" $click={:cancel_release_run, target: "message-" <> @thread_root.id}>Cancel release run</button>
          {/if}
        </div>
        <div>
          {%for reply <- @thread_messages}
            <article class="assembly-message" tabindex="-1" data-assembly-message-id={reply.id} data-assembly-parent-id={reply.reply_to_id} data-assembly-focus-target={if reply.id == @focused_message_id do "true" else "false" end}>
              <MessageAvatar message={reply} />
              <div class="min-w-0">
                <div class="assembly-message-heading">
                  <MessageAuthor message={reply} />
                  {%if Map.get(reply, :source) == "adapter"}
                    <span class="text-xs text-[var(--assembly-chat-muted)]">{reply.source_label}</span>
                  {/if}
                  <a href={reply.permalink} class="assembly-time" aria-label="Link to reply"><time>{reply.time}</time></a>
                </div>
                {%if !Map.get(reply, :release_artifact) && !Map.get(reply, :release_decision)}<MessageBody message={reply} />{/if}
                <AgentSources sources={Map.get(reply, :agent_sources, [])} />
                {%if Map.get(reply, :release_decision)}
                  <ReleaseDecision decision={reply.release_decision} message={reply} pending={decision_pending?(@thread_messages)} viewer_id={@current_user.id} />
                {/if}
                {%if Map.get(reply, :release_artifact)}
                  <ReleaseArtifact artifact={reply.release_artifact} current={release_review_pending?(reply.id, @thread_messages)} publish_available={release_publish_available?(reply.id, @thread_messages)} superseded_by={superseding_version(reply.id, @thread_messages)} viewer_id={@current_user.id} />
                {/if}
                {%if Map.get(reply, :release_publication)}
                  <ReleasePublication proposal={reply.release_publication} status={release_publish_status(reply.release_publication, @thread_messages)} viewer_id={@current_user.id} />
                {/if}
                {%if Map.get(reply, :release_publication_receipt)}
                  <a class="mt-1 inline-block text-sm font-semibold underline" href={reply.release_publication_receipt}>Open published release note</a>
                {/if}
                <Attachments files={Map.get(reply, :attachments, [])} />
                <AgentRunStatus runs={Map.get(reply, :agent_runs, [])} />
                <BridgeDeliveries deliveries={Map.get(reply, :bridge_deliveries, [])} />
                <ThreadReactions message={reply} />
              </div>
            </article>
          {/for}
        </div>
      </div>
      <footer class="assembly-thread-footer">
        {%if @release_error}
          <p class="mb-2 text-sm font-semibold text-[var(--assembly-warm-ink)]" role="alert">{@release_error}</p>
        {/if}
        <form data-assembly-composer="reply" class="assembly-composer assembly-reply-composer" $submit="send_reply">
          <input aria-label="Thread reply" autocomplete="off" name="reply" placeholder="Reply in thread" type="text" value={@reply_draft} $input="reply_draft_changed" />
          <button type="submit" class="assembly-button assembly-primary" disabled={@reply_pending} aria-label="Send reply">Reply</button>
        </form>
        {%if @reply_pending}
          <p class="mt-2 text-sm text-[var(--assembly-chat-muted)]" role="status">Sending reply…</p>
        {/if}
        {%if @reply_error}
          <p class="mt-2 text-sm font-semibold text-[var(--assembly-warm-ink)]" role="alert">{@reply_error}</p>
        {/if}
      </footer>
    </aside>

    """
  end

  defp release_request?(root) do
    match?(%{"type" => "request"}, root.metadata["assembly_release_note"])
  end

  defp decision_pending?(messages) do
    not Enum.any?(messages, fn reply ->
      case reply.metadata["assembly_release_note"] do
        %{"type" => type} -> type in ["decision_answer", "draft", "cancelled"]
        _other -> false
      end
    end)
  end

  defp release_review_pending?(id, messages) do
    latest =
      messages
      |> Enum.reverse()
      |> Enum.find(fn reply ->
        reply[:release_artifact] ||
          match?(%{"type" => "review"}, reply.metadata["assembly_release_note"])
      end)

    not release_cancelled?(messages) && match?(%{id: ^id, release_artifact: %{}}, latest)
  end

  defp release_publish_available?(id, messages) do
    not release_cancelled?(messages) && match?(%{id: ^id}, latest_release_artifact(messages)) &&
      not Enum.any?(messages, &match?(%{release_publication: %{version_id: ^id}}, &1))
  end

  defp superseding_version(id, messages) do
    case latest_release_artifact(messages) do
      %{id: latest, permalink: href, release_artifact: %{version: version}} when latest != id ->
        %{href: href, version: version}

      _current ->
        nil
    end
  end

  defp release_publish_status(%{id: id, version_id: version_id}, messages) do
    events = Enum.map(messages, & &1.metadata["assembly_release_note"])

    cond do
      release_cancelled?(messages) ->
        :cancelled

      Enum.any?(events, &match?(%{"type" => "publish_uncertain", "proposal_id" => ^id}, &1)) ->
        :uncertain

      Enum.any?(events, &match?(%{"type" => "publish_approval", "proposal_id" => ^id}, &1)) ->
        :approved

      Enum.any?(events, &match?(%{"type" => "publish_revocation", "proposal_id" => ^id}, &1)) ->
        :revoked

      not match?(%{id: ^version_id}, latest_release_artifact(messages)) ->
        :superseded

      Enum.any?(events, &match?(%{"type" => "review", "version_id" => ^version_id}, &1)) ->
        :ready

      true ->
        :waiting
    end
  end

  defp latest_release_artifact(messages),
    do: Enum.find(Enum.reverse(messages), &Map.get(&1, :release_artifact))

  defp release_cancel_available?(root, viewer, messages) do
    root.sender_id == viewer &&
      match?(%{"type" => "request"}, root.metadata["assembly_release_note"]) &&
      not Enum.any?(messages, fn reply ->
        case reply.metadata["assembly_release_note"] do
          %{"type" => type} -> type in ["cancelled", "publish_approval"]
          _other -> false
        end
      end)
  end

  defp release_cancelled?(messages),
    do:
      Enum.any?(messages, &match?(%{"type" => "cancelled"}, &1.metadata["assembly_release_note"]))
end
