defmodule Jido.Assembly.Components.Assembly.Sidebar do
  use Hologram.Component

  prop :active_room_id, :string
  prop :channels, :list
  prop :connector_snapshot, :map
  prop :current_user, :map
  prop :demo_users, :list
  prop :direct_messages, :list
  prop :new_room_error, :any
  prop :new_room_name, :string
  prop :new_room_pending, :boolean
  prop :new_room_topic, :string
  prop :rail_target, :string
  prop :room_form_open, :boolean
  prop :search_query, :string
  prop :search_results, :list
  prop :workspace, :map

  def template do
    ~HOLO"""
    <aside class="hidden min-h-0 flex-col bg-[var(--assembly-sidebar)] text-stone-100 md:flex">
      <header class="border-b border-white/8 px-5 py-4">
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold text-stone-400">Workspace</p>
            <h1 class="mt-1 truncate text-lg font-bold text-stone-50" id="assembly-workspace-heading">{@workspace.name}</h1>
          </div>
          <span class="rounded-md bg-[var(--assembly-green)]/18 px-2 py-1 text-xs font-semibold text-emerald-200">
            {@connector_snapshot.headline}
          </span>
        </div>

        <div class="mt-3 grid gap-1.5">
          {%for connector <- @connector_snapshot.connectors}
            <div class="flex items-center justify-between gap-2 rounded-md border border-white/10 bg-white/6 px-2 py-1.5">
              <span class="flex min-w-0 items-center gap-2">
                <span class="grid size-6 place-items-center rounded bg-white/10 text-[10px] font-black text-stone-100">{connector.short_name}</span>
                <span class="truncate text-xs font-semibold text-stone-200">{connector.name}</span>
              </span>
              <span class="shrink-0 rounded px-1.5 py-0.5 text-[11px] font-bold {if connector.mode == "live" do "bg-emerald-300/20 text-emerald-100" else "bg-stone-700 text-stone-300" end}">
                {connector.status}
              </span>
            </div>
          {/for}
        </div>

        <div class="mt-4" id="assembly-demo-users" tabindex="-1">
          <p class="mb-2 text-xs font-semibold text-stone-400">Demo user</p>
          <div class="grid grid-cols-2 gap-1.5">
            {%for user <- @demo_users}
              <button
                class="rounded-md border px-2 py-1.5 text-left text-xs font-semibold transition {if user.id == @current_user.id do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)] text-stone-950" else "border-white/10 bg-white/6 text-stone-300 hover:bg-white/10" end}"
                type="button"
                $click={:select_user, id: user.id}
              >
                {user.name}
              </button>
            {/for}
          </div>
        </div>

        <div class="mt-4">
          <div class="relative">
            <span class="hero-magnifying-glass pointer-events-none absolute left-3 top-2.5 size-4 text-stone-500"></span>
            <input
              class="h-9 w-full rounded-md border bg-stone-950/35 pl-9 pr-3 text-sm text-stone-100 outline-none placeholder:text-stone-500 {if @rail_target == "search" do "border-[var(--assembly-accent)] ring-2 ring-[var(--assembly-accent)]/30" else "border-white/10" end}"
              id="assembly-search-input"
              name="search"
              placeholder="Search messages"
              value={@search_query}
              $change="search_changed"
            />
          </div>
          {%if @search_results != []}
            <div class="mt-2 max-h-44 space-y-1 overflow-y-auto rounded-md border border-white/10 bg-stone-950/50 p-1">
              {%for result <- @search_results}
                <button
                  class="w-full rounded-md px-2 py-1.5 text-left transition hover:bg-white/8"
                  type="button"
                  $click={:select_search_result, room_id: result.room_id, thread_id: result.thread_id}
                >
                  <span class="block truncate text-xs font-bold text-stone-200">{result.room_label} · {result.author}</span>
                  <span class="block truncate text-xs text-stone-400">{result.body}</span>
                </button>
              {/for}
            </div>
          {/if}
        </div>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-3 py-4">
        <section id="assembly-channels-section" tabindex="-1">
          <div class="mb-2 flex items-center justify-between px-2 text-xs font-semibold text-stone-400">
            <span>Channels</span>
            <button class="grid size-7 place-items-center rounded-md text-stone-300 transition hover:bg-white/8" type="button" title="New channel" $click="toggle_room_form">
              <span class="hero-plus size-4"></span>
            </button>
          </div>

          {%if @room_form_open}
            <form class="mb-3 space-y-2 rounded-md border border-white/10 bg-white/6 p-2" $submit="create_channel">
              <input
                class="h-9 w-full rounded-md border border-white/10 bg-stone-950/30 px-3 text-sm text-stone-100 outline-none placeholder:text-stone-500"
                name="name"
                placeholder="channel-name"
                value={@new_room_name}
                $change="new_room_name_changed"
              />
              <input
                class="h-9 w-full rounded-md border border-white/10 bg-stone-950/30 px-3 text-sm text-stone-100 outline-none placeholder:text-stone-500"
                name="topic"
                placeholder="Topic"
                value={@new_room_topic}
                $change="new_room_topic_changed"
              />
              {%if @new_room_error}
                <p class="text-xs text-amber-200">{@new_room_error}</p>
              {/if}
              <button class="inline-flex h-8 w-full items-center justify-center gap-2 rounded-md bg-[var(--assembly-accent)] px-3 text-sm font-bold text-stone-950 transition hover:bg-[var(--assembly-accent-strong)] hover:text-stone-100 disabled:opacity-60" type="submit" disabled={@new_room_pending}>
                <span class="hero-user-group size-4"></span>
                {%if @new_room_pending}Creating{%else}Create channel{/if}
              </button>
            </form>
          {/if}

          <div class="space-y-1">
            {%for channel <- @channels}
              <button
                class="flex w-full items-center justify-between rounded-md px-2.5 py-2 text-left text-sm transition {if channel.id == @active_room_id do "bg-white/12 text-stone-50" else "text-stone-300 hover:bg-white/8 hover:text-stone-50" end}"
                type="button"
                $click={:select_room, id: channel.id}
              >
                <span class="min-w-0 truncate"># {channel.name}</span>
                <span class="ml-2 flex shrink-0 items-center gap-1">
                  {%if channel.mention_unread > 0}
                    <span class="rounded-full bg-amber-200 px-1.5 py-0.5 text-[11px] font-bold text-amber-950">@{channel.mention_unread}</span>
                  {/if}
                  {%if channel.unread > 0}
                    <span class="rounded-full bg-[var(--assembly-accent)] px-2 py-0.5 text-xs font-bold text-stone-950">{channel.unread}</span>
                  {/if}
                </span>
              </button>
            {/for}
          </div>
        </section>

        <section class="mt-6" id="assembly-direct-messages-section" tabindex="-1">
          <div class="mb-2 px-2 text-xs font-semibold text-stone-400">Direct messages</div>
          <div class="space-y-1">
            {%for person <- @direct_messages}
              <button
                class="flex w-full items-center justify-between rounded-md px-2.5 py-2 text-left text-sm transition {if person.id == @active_room_id do "bg-white/12 text-stone-50" else "text-stone-300 hover:bg-white/8 hover:text-stone-50" end}"
                type="button"
                $click={:select_room, id: person.id}
              >
                <span class="flex min-w-0 items-center gap-2">
                  <span class="relative shrink-0">
                    <img class="size-6 rounded-md bg-white/10 object-cover" alt={person.name} src={person.avatar_url} />
                    <span class="absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full border border-[var(--assembly-sidebar)] {if person.online do "bg-[var(--assembly-green)]" else "bg-stone-500" end}"></span>
                  </span>
                  <span class="truncate">{person.name}</span>
                </span>
                {%if person.unread > 0}
                  <span class="ml-3 rounded-full bg-[var(--assembly-accent)] px-2 py-0.5 text-xs font-bold text-stone-950">{person.unread}</span>
                {/if}
              </button>
            {/for}
          </div>
        </section>
      </div>
    </aside>
    """
  end
end
