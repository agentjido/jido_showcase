defmodule Jido.Assembly.Components.Assembly.ChatPanel do
  use Hologram.Component

  alias Jido.Assembly.Components.Assembly.{
    AgentRunStatus,
    Attachments,
    BridgeDeliveries,
    MessageAuthor,
    MessageAvatar,
    MessageBody,
    ReactionDelivery,
    ThreadPanel
  }

  prop :active_room_id, :string
  prop :active_room_name, :string
  prop :active_room_prefix, :string
  prop :active_topic, :string
  prop :agent_demo, :map
  prop :agent_error, :any
  prop :agent_inter_agent_enabled, :boolean
  prop :agent_prompt_draft, :string
  prop :agent_round_pending, :boolean
  prop :agent_safety_enabled, :boolean
  prop :current_user, :map
  prop :draft, :string
  prop :error, :any
  prop :focused_message_id, :any
  prop :history_before, :any
  prop :messages, :list
  prop :pilot, :boolean, default: false
  prop :send_pending, :boolean
  prop :show_agents, :boolean, default: true
  prop :thread_root, :any
  prop :thread_messages, :list
  prop :reply_draft, :string
  prop :reply_error, :any
  prop :reply_pending, :boolean
  prop :release_error, :any

  def template do
    ~HOLO"""
    <section class="assembly-conversation" aria-label="Conversation">
      <div
        class="assembly-chat-scroll"
        data-assembly-chat-scroll
        data-assembly-room-id={@active_room_id}
      >
        <header class="assembly-thread-heading">
          <h2>{conversation_title(@active_room_id, @active_room_name)}</h2>
          {%if @active_topic != ""}<p>{@active_topic}</p>{/if}
          {%if !@pilot}<details class="assembly-ops">
            <summary>Ops agents</summary>
            <div class="mt-2 grid gap-2 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)]/80 px-3 py-2">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                {%for agent <- @agent_demo.agents}
                  <span class="inline-flex items-center gap-1.5 rounded-full border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] px-2 py-1 text-xs font-semibold text-[var(--assembly-chat-text)]" title={agent.title}>
                    <span class="grid size-5 place-items-center rounded {agent.tone} text-[10px] font-black">{agent.initials}</span>
                    {agent.name}
                  </span>
                {/for}
                <span class="inline-flex h-7 items-center rounded-full border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] px-2 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                  {@agent_demo.safety.max_rounds_per_prompt} rounds/question
                </span>
                {%if @agent_demo.missing_api_key}
                  <span class="inline-flex h-7 items-center rounded-full border border-amber-500/30 bg-amber-300/12 px-2 text-xs font-semibold text-[var(--assembly-warm-ink)]">
                    Configure a live model to run the agents
                  </span>
                {/if}
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <label class="inline-flex h-8 items-center gap-1.5 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-input)] px-2.5 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                  <input
                    class="size-3.5 accent-[var(--assembly-accent)]"
                    type="checkbox"
                    checked={@agent_safety_enabled}
                    $change="agent_safety_changed"
                  />
                  Safety cap
                </label>

                <label class="inline-flex h-8 items-center gap-1.5 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-input)] px-2.5 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                  <input
                    class="size-3.5 accent-[var(--assembly-accent)]"
                    type="checkbox"
                    checked={@agent_inter_agent_enabled}
                    $change="agent_inter_agent_changed"
                  />
                  Agent chat
                </label>

                <button
                  class="inline-flex h-8 items-center gap-2 rounded-md bg-[var(--assembly-chat-text)] px-3 text-xs font-bold text-[var(--assembly-chat-bg)] transition hover:bg-[var(--assembly-chat-muted)] disabled:opacity-50"
                  type="button"
                  disabled={@agent_round_pending || @agent_demo.missing_api_key}
                  title="Continue latest human prompt"
                  $click="run_agent_round"
                >
                  <span class="hero-bolt size-4"></span>
                  {%if @agent_round_pending}Running{%else}Continue{/if}
                </button>
              </div>

              <form class="flex min-w-0 gap-2" $submit="prompt_agent_round">
                <input
                  class="h-9 min-w-0 flex-1 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-input)] px-3 text-sm text-[var(--assembly-chat-text)] outline-none placeholder:text-[var(--assembly-chat-subtle)] focus:border-[var(--assembly-accent)] focus:ring-2 focus:ring-[var(--assembly-accent)]/25"
                  aria-label="Ask AI agents"
                  autocomplete="off"
                  name="agent_prompt"
                  placeholder="Ask the ops agents"
                  type="text"
                  value={@agent_prompt_draft}
                  $input="agent_prompt_changed"
                />
                <button
                  class="inline-flex h-9 items-center gap-2 rounded-md bg-[var(--assembly-accent)] px-3 text-xs font-bold text-white transition hover:bg-[var(--assembly-accent-strong)] hover:text-stone-100 disabled:opacity-50"
                  type="submit"
                  disabled={@agent_round_pending || @agent_demo.missing_api_key}
                  title="Ask agents"
                >
                  <span class="hero-paper-airplane size-4"></span>
                  Ask
                </button>
              </form>
            </div>

            {%if @agent_error}
              <p class="mt-2 text-sm font-semibold text-[var(--assembly-warm-ink)]">{@agent_error}</p>
            {/if}
          </details>{/if}
        </header>
        <div class="assembly-timeline" data-assembly-message-list>
          <h3 class="assembly-divider">Conversation</h3>
          {%if @history_before}
            <button type="button" class="assembly-text-link mb-2" $click="load_older_history">Load earlier messages</button>
          {/if}
          {%for message <- @messages}
            <article
              class="assembly-message assembly-room-message group"
              data-assembly-message-id={message.id}
              data-assembly-focus-target={if message.id == @focused_message_id do "true" else "false" end}
              data-assembly-room-message
              tabindex="-1"
            >
              <MessageAvatar message={message} />
              <div class="min-w-0">
                <div class="assembly-message-heading">
                  <MessageAuthor message={message} />
                  <a href={message.permalink} class="assembly-time" aria-label="Link to message"><time>{message.time}</time></a>
                  {%if message.source_label != "Local"}
                    <span class="rounded-full border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] px-2 py-0.5 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                      {message.source_label}
                    </span>
                  {/if}
                  {%if message.source_detail != ""}
                    <span class="text-xs text-[var(--assembly-chat-subtle)]">{message.source_detail}</span>
                  {/if}
                  {%if message.mentions_current_user}
                    <span class="rounded-full bg-amber-300/18 px-2 py-0.5 text-xs font-bold text-[var(--assembly-warm-ink)]">@you</span>
                  {/if}
                </div>
                {%if message.workflow}
                  <div class="mt-2 max-w-[74ch] rounded-md border border-emerald-500/30 bg-emerald-300/10 px-3 py-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="hero-bolt size-4 text-emerald-800"></span>
                      <span class="text-xs font-bold uppercase text-emerald-900">{message.workflow.event_type}</span>
                      <span class="rounded bg-emerald-300/16 px-1.5 py-0.5 text-[11px] font-semibold text-emerald-900">{message.workflow.state}</span>
                      <span class="rounded bg-amber-300/16 px-1.5 py-0.5 text-[11px] font-semibold text-[var(--assembly-warm-ink)]">{message.workflow.severity}</span>
                    </div>
                    <MessageBody message={message} />
                    <div class="mt-2 flex flex-wrap gap-1.5">
                      {%for action <- message.workflow.actions}
                        <span class="rounded border border-emerald-500/30 bg-emerald-300/10 px-2 py-0.5 text-xs font-semibold text-emerald-900">{action}</span>
                      {/for}
                    </div>
                  </div>
                {%else}
                  <MessageBody message={message} />
                {/if}
                {%if message.delivery.route_decision != "local"}
                  <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-[var(--assembly-chat-subtle)]">
                    <span class="rounded bg-[var(--assembly-chat-pill)] px-2 py-0.5 font-semibold">
                      delivery: {message.delivery.route_decision}
                    </span>
                    <span>{message.delivery.delivered}/{message.delivery.attempted} delivered</span>
                    {%if message.delivery.error != ""}
                      <span class="text-[var(--assembly-warm-ink)]">{message.delivery.error}</span>
                    {/if}
                  </div>
                {/if}
                <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
                  {%for reaction <- message.reactions}
                    <button
                      class="inline-flex h-6 items-center gap-1.5 rounded-full border px-2 text-xs font-semibold shadow-sm transition {if reaction.reacted do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)]/25 text-[var(--assembly-chat-text)]" else "border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] text-[var(--assembly-chat-muted)] hover:border-[var(--assembly-chat-muted)] hover:text-[var(--assembly-chat-text)]" end}"
                      type="button"
                      title={reaction.label}
                      $click={:set_reaction, message_id: message.id, emoji: reaction.emoji, active: !reaction.reacted}
                    >
                      <span class="text-sm leading-none">{reaction.glyph}</span>
                      <span>{reaction.count}</span>
                    </button>
                  {/for}
                </div>
                <Attachments files={Map.get(message, :attachments, [])} />
                <AgentRunStatus runs={Map.get(message, :agent_runs, [])} />
                <BridgeDeliveries deliveries={Map.get(message, :bridge_deliveries, [])} />
                <ReactionDelivery destinations={Map.get(message, :reaction_delivery, [])} />
                <button class="assembly-thread-link" type="button" aria-label="Reply in thread" data-assembly-thread-trigger={message.id} aria-expanded={if @thread_root && @thread_root.id == message.id do "true" else "false" end} $click={:open_thread, message_id: message.id}>
                  <span class="hero-chat-bubble-left-ellipsis size-4" aria-hidden="true"></span>
                  {thread_label(message)}
                </button>
              </div>
              <div class="assembly-message-tools">
                {%for option <- message.available_reactions}
                  <button
                    class="grid size-7 place-items-center rounded-full text-sm text-[var(--assembly-chat-muted)] transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]"
                    type="button"
                    title={option.label}
                    aria-label={option.label}
                    $click={:set_reaction, message_id: message.id, emoji: option.key, active: true}
                  >
                    <span class="leading-none">{option.glyph}</span>
                  </button>
                {/for}
              </div>
            </article>
            {%if @thread_root && @thread_root.id == message.id}
              <ThreadPanel current_user={@current_user} focused_message_id={@focused_message_id} reply_draft={@reply_draft} reply_error={@reply_error} reply_pending={@reply_pending} release_error={@release_error} thread_root={@thread_root} thread_messages={@thread_messages} mobile={false} />
              <ThreadPanel current_user={@current_user} focused_message_id={@focused_message_id} reply_draft={@reply_draft} reply_error={@reply_error} reply_pending={@reply_pending} release_error={@release_error} thread_root={@thread_root} thread_messages={@thread_messages} mobile={true} />
            {/if}
          {/for}
          <div data-assembly-chat-end aria-hidden="true"></div>
        </div>
      </div>

      <footer class="assembly-composer-wrap">
        <form data-assembly-composer="message" class="assembly-composer" $submit="send_message">
          <input
            aria-label="Message body"
            autocomplete="off"
            name="body"
            placeholder="Message {@active_room_prefix}{@active_room_name}"
            type="text"
            value={@draft}
            $input="draft_changed"
          />
          <div class="assembly-composer-actions">
            {%if @show_agents}<button type="button" class="assembly-text-link" $click="mention_triage">@ Ask Triage</button>{/if}
            <button type="submit" class="assembly-button assembly-primary" disabled={@send_pending} aria-label="Send message">Send</button>
          </div>
        </form>
        {%if @send_pending}
          <p class="mt-2 text-sm text-[var(--assembly-chat-muted)]" role="status">Sending message…</p>
        {/if}
        {%if @error}
          <p class="mt-2 text-sm font-semibold text-[var(--assembly-warm-ink)]" role="alert">{@error}</p>
        {/if}
      </footer>
    </section>
    """
  end

  defp conversation_title("room:jido-chat-release", _name),
    do: "Prepare the Jido Chat release note"

  defp conversation_title(_id, name), do: name

  defp thread_label(%{metadata: %{"assembly_release_note" => %{"type" => "request"}}}),
    do: "Triage thread"

  defp thread_label(%{reply_count: 1}), do: "1 reply"

  defp thread_label(%{reply_count: count}) when count > 1,
    do: Integer.to_string(count) <> " replies"

  defp thread_label(_message), do: "Reply"
end
