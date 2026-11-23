defmodule Jido.Assembly.Components.Assembly.Sidebar do
  use Hologram.Component

  prop :active_room_id, :string
  prop :channels, :list
  prop :direct_messages, :list
  prop :new_room_error, :any
  prop :new_room_name, :string
  prop :new_room_pending, :boolean
  prop :new_room_topic, :string
  prop :release_work, :any
  prop :pilot, :boolean, default: false
  prop :room_form_open, :boolean
  prop :search_query, :string
  prop :search_results, :list
  prop :workspace, :map
  prop :workspace_view, :string

  def template do
    ~HOLO"""
    <aside class="assembly-sidebar" aria-label="Workspace">
      <div class="assembly-workspace-name">
        <span class="assembly-workspace-avatar" aria-hidden="true">J</span>
        <strong id="assembly-workspace-heading">{@workspace.name}</strong>
      </div>

      <nav class="assembly-nav" aria-label="Work">
        <button type="button" class="assembly-nav-link" aria-current={current(@workspace_view == "threads")} $click={:show_workspace_view, view: "threads"}>All threads</button>
        {%if !@pilot}<button type="button" class="assembly-nav-link" aria-current={current(@workspace_view == "inbox")} $click={:show_workspace_view, view: "inbox"}>
          Needs you
          {%if @release_work && @release_work.inbox != []}
            <span class="assembly-count" data-assembly-needs-count>{length(@release_work.inbox)}</span>
          {/if}
        </button>
        <button type="button" class="assembly-nav-link" aria-current={current(@workspace_view == "board")} $click={:show_workspace_view, view: "board"}>Board</button>{/if}
      </nav>

      <nav class="assembly-channels" id="assembly-channels-section" aria-label="Channels" tabindex="-1">
        <div class="assembly-nav-heading">
          <h2>Channels</h2>
          <button class="assembly-icon-button" type="button" aria-label="New channel" title="New channel" $click="toggle_room_form">
            <span class="hero-plus size-4"></span>
          </button>
        </div>
        {%if @room_form_open}
          <form class="mb-3 space-y-2 rounded-md border border-[var(--assembly-line)] bg-white p-2" $submit="create_channel">
            <input
              class="h-9 w-full rounded-md border border-[var(--assembly-line)] bg-white px-3 text-sm text-[var(--assembly-ink)] outline-none placeholder:text-stone-500"
              name="name"
              placeholder="channel-name"
              value={@new_room_name}
              $change="new_room_name_changed"
            />
            <input
              class="h-9 w-full rounded-md border border-[var(--assembly-line)] bg-white px-3 text-sm text-[var(--assembly-ink)] outline-none placeholder:text-stone-500"
              name="topic"
              placeholder="Topic"
              value={@new_room_topic}
              $change="new_room_topic_changed"
            />
            {%if @new_room_error}
              <p class="text-xs text-[var(--assembly-warm-ink)]">{@new_room_error}</p>
            {/if}
            <button class="inline-flex h-8 w-full items-center justify-center gap-2 rounded-md bg-[var(--assembly-accent)] px-3 text-sm font-bold text-white transition hover:bg-[var(--assembly-accent-strong)] disabled:opacity-60" type="submit" disabled={@new_room_pending}>
              <span class="hero-user-group size-4"></span>
              {%if @new_room_pending}Creating{%else}Create channel{/if}
            </button>
          </form>
        {/if}

        <div class="assembly-room-links">
          {%for channel <- @channels}
            <button type="button" class="assembly-room-link" aria-current={current(@workspace_view == "chat" && channel.id == @active_room_id)} $click={:select_room, id: channel.id}>
              <span class="assembly-muted" aria-hidden="true">#</span>
              <span class="truncate">{channel.name}</span>
              {%if channel.mention_unread > 0}
                <span class="assembly-count">@{channel.mention_unread}</span>
              {%else}
                {%if channel.unread > 0}
                  <span class="assembly-count">{channel.unread}</span>
                {/if}
              {/if}
            </button>
          {/for}
        </div>
      </nav>

      <details class="assembly-direct-messages" id="assembly-direct-messages-section" tabindex="-1">
        <summary>Direct messages</summary>
        <nav class="assembly-room-links" aria-label="Direct messages">
          {%for person <- @direct_messages}
            <button type="button" class="assembly-room-link" aria-current={current(@workspace_view == "chat" && person.id == @active_room_id)} $click={:select_room, id: person.id}>
              <span class="relative shrink-0">
                <img class="size-5 rounded object-cover" alt="" src={person.avatar_url} />
                {%if person.online}<span class="assembly-online" aria-label="Online"></span>{/if}
              </span>
              <span class="truncate">{person.name}</span>
              {%if person.unread > 0}<span class="assembly-count">{person.unread}</span>{/if}
            </button>
          {/for}
        </nav>
      </details>

      <div class="assembly-sidebar-footer">
        <input type="search" class="assembly-search" id="assembly-search-input" aria-label="Search messages" name="search" placeholder="Search messages" value={@search_query} $change="search_changed" />
        {%if @search_results != []}
          <div class="mt-2 max-h-44 space-y-1 overflow-y-auto rounded-md border border-[var(--assembly-line)] bg-white p-1">
            {%for result <- @search_results}
              <button
                class="w-full rounded-md px-2 py-1.5 text-left transition hover:bg-[var(--assembly-selected)]"
                type="button"
                $click={:select_search_result, room_id: result.room_id, thread_id: result.thread_id, message_id: result.message_id}
              >
                <span class="block truncate text-xs font-bold text-[var(--assembly-ink)]">{result.room_label} · {result.author}</span>
                <span class="block truncate text-xs text-[var(--assembly-muted)]">{result.body}</span>
              </button>
            {/for}
          </div>
        {/if}

        {%if !@pilot}<a class="assembly-text-link" href="/release-notes">Release notes demo</a>{/if}
      </div>
    </aside>
    """
  end

  defp current(true), do: "page"
  defp current(false), do: "false"
end
