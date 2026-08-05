defmodule Jido.Assembly.Components.Assembly.ChatPanel do
  use Hologram.Component

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
  prop :connector_snapshot, :map
  prop :current_user, :map
  prop :draft, :string
  prop :error, :any
  prop :member_count_label, :string
  prop :messages, :list
  prop :rooms, :list
  prop :send_pending, :boolean
  prop :workspace, :map

  def template do
    ~HOLO"""
    <section class="flex min-h-0 flex-col bg-[var(--assembly-chat-bg)] text-[var(--assembly-chat-text)]">
      <header class="border-b border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-header)] px-4 py-3 sm:px-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0">
            <p class="mb-1 text-xs font-semibold text-[var(--assembly-chat-muted)] md:hidden">{@workspace.name}</p>
            <div class="flex items-center gap-3">
              <h2 class="truncate text-xl font-bold text-[var(--assembly-chat-text)]">{@active_room_prefix}{@active_room_name}</h2>
              <span class="rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] px-2 py-1 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                {@member_count_label}
              </span>
            </div>
            <p class="mt-1 max-w-[70ch] truncate text-sm text-[var(--assembly-chat-muted)]">{@active_topic}</p>
          </div>
          <div class="flex items-center gap-2">
            <span class="hidden items-center gap-2 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] px-2 py-1.5 text-sm font-semibold text-[var(--assembly-chat-muted)] sm:inline-flex">
              <img class="size-7 rounded-md bg-[var(--assembly-chat-pill)] object-cover" alt={@current_user.name} src={@current_user.avatar_url} />
              As {@current_user.name}
            </span>
          </div>
        </div>

        <div class="mt-3 flex gap-2 overflow-x-auto pb-1 md:hidden">
          {%for room <- @rooms}
            <button
              class="shrink-0 rounded-md border px-3 py-1.5 text-sm font-semibold transition {if room.id == @active_room_id do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)] text-stone-950" else "border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] text-[var(--assembly-chat-muted)]" end}"
              type="button"
              $click={:select_room, id: room.id}
            >
              {room.prefix}{room.name}
            </button>
          {/for}
        </div>

        <div class="mt-3 grid gap-2 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)]/80 px-3 py-2 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="inline-flex items-center gap-1.5 text-xs font-bold uppercase tracking-wide text-[var(--assembly-chat-muted)]">
              <span class="hero-sparkles size-4"></span>
              Ops agents
            </span>
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
              <span class="inline-flex h-7 items-center rounded-full border border-amber-500/30 bg-amber-300/12 px-2 text-xs font-semibold text-amber-200">
                ANTHROPIC_API_KEY required for live actions
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

          <form class="flex min-w-0 gap-2 lg:col-span-2" $submit="prompt_agent_round">
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
              class="inline-flex h-9 items-center gap-2 rounded-md bg-[var(--assembly-accent)] px-3 text-xs font-bold text-stone-950 transition hover:bg-[var(--assembly-accent-strong)] hover:text-stone-100 disabled:opacity-50"
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
          <p class="mt-2 text-sm font-semibold text-amber-200">{@agent_error}</p>
        {/if}
      </header>

      <div
        class="min-h-0 flex-1 overflow-y-auto py-3"
        data-assembly-chat-scroll
        data-assembly-room-id={@active_room_id}
      >
        <div class="space-y-1" data-assembly-message-list>
          <div class="mx-4 mb-3 rounded-md border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] px-4 py-3 text-sm text-[var(--assembly-chat-muted)] sm:mx-6">
            Ops workflow showcase: local chat, provider connectors, workflow events, threads, reactions, and agents all persist through jido_messaging.
            <span class="ml-2 font-semibold text-[var(--assembly-chat-text)]">{@connector_snapshot.headline}</span>
          </div>

          {%for message <- @messages}
            <article
              class="group relative flex gap-3 px-4 py-1.5 transition hover:bg-[var(--assembly-chat-hover)] sm:px-6"
              data-assembly-message-id={message.id}
            >
              <img class="mt-0.5 size-9 shrink-0 rounded-md bg-[var(--assembly-chat-pill)] object-cover shadow-sm" alt={message.author} src={message.avatar_url} />
              <div class="min-w-0 flex-1 pr-2 sm:pr-44">
                <div class="flex flex-wrap items-baseline gap-2">
                  <h3 class="text-sm font-bold text-[var(--assembly-chat-text)]">{message.author}</h3>
                  <time class="text-xs text-[var(--assembly-chat-muted)]">{message.time}</time>
                  {%if message.source_label != "Local"}
                    <span class="rounded-full border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] px-2 py-0.5 text-xs font-semibold text-[var(--assembly-chat-muted)]">
                      {message.source_label}
                    </span>
                  {/if}
                  {%if message.source_detail != ""}
                    <span class="text-xs text-[var(--assembly-chat-subtle)]">{message.source_detail}</span>
                  {/if}
                  {%if message.mentions_current_user}
                    <span class="rounded-full bg-amber-300/18 px-2 py-0.5 text-xs font-bold text-amber-200">@you</span>
                  {/if}
                </div>
                {%if message.workflow}
                  <div class="mt-2 max-w-[74ch] rounded-md border border-emerald-500/30 bg-emerald-300/10 px-3 py-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="hero-bolt size-4 text-emerald-200"></span>
                      <span class="text-xs font-bold uppercase text-emerald-100">{message.workflow.event_type}</span>
                      <span class="rounded bg-emerald-300/16 px-1.5 py-0.5 text-[11px] font-semibold text-emerald-100">{message.workflow.state}</span>
                      <span class="rounded bg-amber-300/16 px-1.5 py-0.5 text-[11px] font-semibold text-amber-100">{message.workflow.severity}</span>
                    </div>
                    <p class="mt-2 text-sm leading-6 text-[var(--assembly-chat-text)]">{message.body}</p>
                    <div class="mt-2 flex flex-wrap gap-1.5">
                      {%for action <- message.workflow.actions}
                        <span class="rounded border border-emerald-500/30 bg-emerald-300/10 px-2 py-0.5 text-xs font-semibold text-emerald-100">{action}</span>
                      {/for}
                    </div>
                  </div>
                {%else}
                  <p class="mt-1 max-w-[74ch] text-sm leading-6 text-[var(--assembly-chat-text)]">{message.body}</p>
                {/if}
                {%if message.delivery.route_decision != "local"}
                  <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-[var(--assembly-chat-subtle)]">
                    <span class="rounded bg-[var(--assembly-chat-pill)] px-2 py-0.5 font-semibold">
                      delivery: {message.delivery.route_decision}
                    </span>
                    <span>{message.delivery.delivered}/{message.delivery.attempted} delivered</span>
                    {%if message.delivery.error != ""}
                      <span class="text-amber-200">{message.delivery.error}</span>
                    {/if}
                  </div>
                {/if}
                <div class="mt-1.5 flex flex-wrap items-center gap-1.5">
                  {%for reaction <- message.reactions}
                    <button
                      class="inline-flex h-6 items-center gap-1.5 rounded-full border px-2 text-xs font-semibold shadow-sm transition {if reaction.reacted do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)]/25 text-[var(--assembly-chat-text)]" else "border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-pill)] text-[var(--assembly-chat-muted)] hover:border-[var(--assembly-chat-muted)] hover:text-[var(--assembly-chat-text)]" end}"
                      type="button"
                      title={reaction.label}
                      $click={:toggle_reaction, message_id: message.id, emoji: reaction.emoji}
                    >
                      <span class="text-sm leading-none">{reaction.glyph}</span>
                      <span>{reaction.count}</span>
                    </button>
                  {/for}
                  <button
                    class="inline-flex h-6 items-center gap-1.5 rounded-full border border-transparent px-2 text-xs font-semibold text-[var(--assembly-chat-muted)] transition hover:border-[var(--assembly-chat-line)] hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)] sm:hidden {if message.reply_count > 0 do "" else "opacity-80" end}"
                    type="button"
                    $click={:open_thread, message_id: message.id}
                  >
                    <span class="hero-chat-bubble-left-ellipsis size-4"></span>
                    {%if message.reply_count > 0}{message.reply_count} replies{%else}Reply{/if}
                  </button>
                </div>
              </div>
              <div class="absolute right-4 top-1 hidden items-center gap-0.5 rounded-full border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-raised)] p-1 shadow-lg sm:group-hover:flex">
                {%for option <- message.available_reactions}
                  <button
                    class="grid size-7 place-items-center rounded-full text-sm text-[var(--assembly-chat-muted)] transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]"
                    type="button"
                    title={option.label}
                    aria-label={option.label}
                    $click={:toggle_reaction, message_id: message.id, emoji: option.key}
                  >
                    <span class="leading-none">{option.glyph}</span>
                  </button>
                {/for}
                <button
                  class="grid size-7 place-items-center rounded-full text-[var(--assembly-chat-muted)] transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]"
                  type="button"
                  title="Reply in thread"
                  aria-label="Reply in thread"
                  $click={:open_thread, message_id: message.id}
                >
                  <span class="hero-chat-bubble-left-ellipsis size-4"></span>
                </button>
                <button class="grid size-7 place-items-center rounded-full text-[var(--assembly-chat-muted)] transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="More actions" aria-label="More actions">
                  <span class="hero-ellipsis-vertical size-4"></span>
                </button>
              </div>
            </article>
          {/for}
          <div data-assembly-chat-end aria-hidden="true"></div>
        </div>
      </div>

      <footer class="border-t border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-bg)] px-4 py-4 sm:px-6">
        <form data-assembly-composer="message" class="mx-auto max-w-5xl overflow-hidden rounded-lg border border-[var(--assembly-chat-line)] bg-[var(--assembly-chat-input)] shadow-sm transition focus-within:border-[var(--assembly-chat-muted)] focus-within:ring-2 focus-within:ring-[var(--assembly-accent)]/25" $submit="send_message">
          <div class="flex h-9 items-center gap-0.5 border-b border-[var(--assembly-chat-line)] px-2 text-[var(--assembly-chat-subtle)]">
            <button class="grid size-7 place-items-center rounded-md text-sm font-bold transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Bold" aria-label="Bold">B</button>
            <button class="grid size-7 place-items-center rounded-md text-sm italic transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Italic" aria-label="Italic">I</button>
            <button class="grid size-7 place-items-center rounded-md text-sm underline transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Underline" aria-label="Underline">U</button>
            <button class="grid size-7 place-items-center rounded-md text-sm line-through transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Strike" aria-label="Strike">S</button>
            <span class="mx-1 h-5 w-px bg-[var(--assembly-chat-line)]"></span>
            <button class="grid size-7 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Link" aria-label="Link">
              <span class="hero-link size-4"></span>
            </button>
            <button class="grid size-7 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Numbered list" aria-label="Numbered list">
              <span class="hero-numbered-list size-4"></span>
            </button>
            <button class="grid size-7 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Bulleted list" aria-label="Bulleted list">
              <span class="hero-list-bullet size-4"></span>
            </button>
            <span class="mx-1 h-5 w-px bg-[var(--assembly-chat-line)]"></span>
            <button class="grid size-7 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Code" aria-label="Code">
              <span class="hero-code-bracket size-4"></span>
            </button>
          </div>
          <input
            class="h-12 w-full min-w-0 bg-transparent px-3 py-2 text-sm leading-6 text-[var(--assembly-chat-text)] outline-none placeholder:text-[var(--assembly-chat-subtle)]"
            aria-label="Message body"
            autocomplete="off"
            name="body"
            placeholder="Message {@active_room_prefix}{@active_room_name}. Try @maggie"
            type="text"
            value={@draft}
            $input="draft_changed"
          />
          <div class="flex h-10 items-center justify-between border-t border-[var(--assembly-chat-line)] px-2">
            <div class="flex items-center gap-0.5 text-[var(--assembly-chat-muted)]">
              <button class="grid size-8 place-items-center rounded-full bg-[var(--assembly-chat-pill)] transition hover:text-[var(--assembly-chat-text)]" type="button" title="Add attachment" aria-label="Add attachment">
                <span class="hero-plus size-5"></span>
              </button>
              <button class="grid size-8 place-items-center rounded-md text-sm font-semibold transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Formatting" aria-label="Formatting">Aa</button>
              <button class="grid size-8 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Emoji" aria-label="Emoji">
                <span class="hero-face-smile size-4"></span>
              </button>
              <button class="grid size-8 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Mention" aria-label="Mention">
                <span class="text-lg leading-none">@</span>
              </button>
              <button class="grid size-8 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Record clip" aria-label="Record clip">
                <span class="hero-video-camera size-4"></span>
              </button>
              <button class="grid size-8 place-items-center rounded-md transition hover:bg-[var(--assembly-chat-pill)] hover:text-[var(--assembly-chat-text)]" type="button" title="Voice" aria-label="Voice">
                <span class="hero-microphone size-4"></span>
              </button>
            </div>
            <button class="grid size-8 place-items-center rounded-md bg-[var(--assembly-accent)] text-stone-950 transition hover:bg-[var(--assembly-accent-strong)] hover:text-stone-100 disabled:opacity-60" type="submit" disabled={@send_pending} title="Send message" aria-label="Send message">
              <span class="hero-paper-airplane size-4"></span>
            </button>
          </div>
        </form>
        {%if @error}
          <p class="mx-auto mt-2 max-w-5xl text-sm font-semibold text-amber-200">{@error}</p>
        {/if}
      </footer>
    </section>
    """
  end
end
