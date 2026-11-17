defmodule Jido.Assembly.Components.Assembly.MobileWorkspacePanel do
  use Hologram.Component

  prop :active_room_id, :string
  prop :connector_snapshot, :map
  prop :current_user, :map
  prop :demo_users, :list
  prop :developer_contract, :list
  prop :developer_message_inspector, :map
  prop :developer_room_metrics, :list
  prop :developer_stack, :list
  prop :last_event, :map
  prop :mobile_panel, :string
  prop :new_room_error, :any
  prop :new_room_name, :string
  prop :new_room_pending, :boolean
  prop :new_room_topic, :string
  prop :presence, :map
  prop :room_form_open, :boolean
  prop :rooms, :list
  prop :search_query, :string
  prop :search_results, :list

  def template do
    ~HOLO"""
    {%if @mobile_panel != ""}
      <div class="fixed inset-0 z-50 md:hidden">
        <button
          aria-label="Close mobile panel"
          class="absolute inset-0 bg-stone-950/70"
          type="button"
          $click="close_mobile_panel"
        ></button>

        <aside
          aria-label="Workspace tools and developer inspector"
          aria-modal="true"
          class="absolute inset-y-0 right-0 flex w-[min(92vw,420px)] flex-col border-l border-white/10 bg-[var(--assembly-sidebar)] text-stone-100 shadow-2xl"
          id="assembly-mobile-panel"
          role="dialog"
          tabindex="-1"
          $key_down.escape="close_mobile_panel"
        >
          <header class="flex items-center justify-between border-b border-white/10 px-4 py-3">
            <div>
              <h2 class="text-sm font-bold">
                {if @mobile_panel == "workspace" do "Workspace tools" else "Developer inspector" end}
              </h2>
              <p class="mt-1 text-xs text-stone-400">
                {if @mobile_panel == "workspace" do "Rooms, search, people, and connectors" else "Jido Chat V3 runtime evidence" end}
              </p>
            </div>
            <button
              aria-label="Close mobile panel"
              class="grid size-9 place-items-center rounded-md text-stone-300 transition hover:bg-white/10 hover:text-white"
              title="Close"
              type="button"
              $click="close_mobile_panel"
            >
              <span class="hero-x-mark size-5"></span>
            </button>
          </header>

          <div class="min-h-0 flex-1 space-y-5 overflow-y-auto p-4">
            {%if @mobile_panel == "workspace"}
              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Search</h3>
                <input
                  aria-label="Search messages"
                  class="h-10 w-full rounded-md border border-white/10 bg-stone-950/35 px-3 text-sm text-stone-100 outline-none placeholder:text-stone-500 focus:border-[var(--assembly-accent)]"
                  id="assembly-mobile-search-input"
                  name="search"
                  placeholder="Search messages"
                  value={@search_query}
                  $change="search_changed"
                />
                {%if @search_results != []}
                  <div class="mt-2 space-y-1 rounded-md border border-white/10 bg-stone-950/40 p-1">
                    {%for result <- @search_results}
                      <button
                        class="w-full rounded-md px-2 py-2 text-left transition hover:bg-white/8"
                        type="button"
                        $click={:select_search_result, room_id: result.room_id, thread_id: result.thread_id}
                      >
                        <span class="block truncate text-xs font-bold text-stone-200">{result.room_label} · {result.author}</span>
                        <span class="block truncate text-xs text-stone-400">{result.body}</span>
                      </button>
                    {/for}
                  </div>
                {/if}
              </section>

              <section>
                <div class="mb-2 flex items-center justify-between">
                  <h3 class="text-xs font-semibold uppercase tracking-wide text-stone-400">Rooms</h3>
                  <button
                    class="rounded-md border border-white/10 bg-white/6 px-2 py-1 text-xs font-semibold text-stone-200"
                    type="button"
                    $click="toggle_room_form"
                  >
                    New Room
                  </button>
                </div>
                {%if @room_form_open}
                  <form class="mb-3 space-y-2 rounded-md border border-white/10 bg-white/6 p-3" $submit="create_channel">
                    <input
                      aria-label="Room name"
                      class="h-10 w-full rounded-md border border-white/10 bg-stone-950/30 px-3 text-sm text-stone-100 outline-none"
                      name="name"
                      placeholder="channel-name"
                      value={@new_room_name}
                      $change="new_room_name_changed"
                    />
                    <input
                      aria-label="Room topic"
                      class="h-10 w-full rounded-md border border-white/10 bg-stone-950/30 px-3 text-sm text-stone-100 outline-none"
                      name="topic"
                      placeholder="Topic"
                      value={@new_room_topic}
                      $change="new_room_topic_changed"
                    />
                    {%if @new_room_error}
                      <p class="text-xs text-amber-200">{@new_room_error}</p>
                    {/if}
                    <button
                      class="h-9 w-full rounded-md bg-[var(--assembly-accent)] px-3 text-sm font-bold text-stone-950 disabled:opacity-60"
                      disabled={@new_room_pending}
                      type="submit"
                    >
                      {%if @new_room_pending}Creating{%else}Create Room{/if}
                    </button>
                  </form>
                {/if}
                <div class="grid grid-cols-2 gap-2">
                  {%for room <- @rooms}
                    <button
                      class="truncate rounded-md border px-2 py-2 text-left text-sm {if room.id == @active_room_id do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)] text-stone-950" else "border-white/10 bg-white/6 text-stone-200" end}"
                      type="button"
                      $click={:select_room, id: room.id}
                    >
                      {room.prefix}{room.name}
                    </button>
                  {/for}
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Demo user</h3>
                <div class="grid grid-cols-2 gap-2">
                  {%for user <- @demo_users}
                    <button
                      class="rounded-md border px-2 py-2 text-left text-xs font-semibold {if user.id == @current_user.id do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)] text-stone-950" else "border-white/10 bg-white/6 text-stone-200" end}"
                      type="button"
                      $click={:select_user, id: user.id}
                    >
                      {user.name}
                    </button>
                  {/for}
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Connectors</h3>
                <div class="space-y-2">
                  {%for connector <- @connector_snapshot.connectors}
                    <div class="rounded-md border border-white/10 bg-white/6 p-3 text-sm">
                      <div class="flex items-center justify-between gap-3">
                        <span class="font-semibold">{connector.name}</span>
                        <span class="rounded bg-stone-800 px-2 py-0.5 text-xs text-stone-300">{connector.status}</span>
                      </div>
                      <p class="mt-1 break-all text-xs text-stone-400">{connector.adapter_module}</p>
                      <p class="mt-1 text-xs text-stone-400">{connector.target_label}</p>
                    </div>
                  {/for}
                </div>
              </section>
            {%else}
              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Conversation</h3>
                <div class="grid grid-cols-2 gap-2">
                  {%for metric <- @developer_room_metrics}
                    <div class="rounded-md border border-white/10 bg-white/6 p-2 text-xs">
                      <span class="block text-stone-400">{metric.label}</span>
                      <span class="mt-1 block font-semibold text-stone-100">{metric.value}</span>
                    </div>
                  {/for}
                  <div class="rounded-md border border-white/10 bg-white/6 p-2 text-xs">
                    <span class="block text-stone-400">Online users</span>
                    <span class="mt-1 block font-semibold text-stone-100">{Enum.count(@presence.online_user_ids)}</span>
                  </div>
                  <div class="rounded-md border border-white/10 bg-white/6 p-2 text-xs">
                    <span class="block text-stone-400">Browser sessions</span>
                    <span class="mt-1 block font-semibold text-stone-100">{Enum.count(@presence.sessions)}</span>
                  </div>
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Last Signal</h3>
                <div class="rounded-md border border-white/10 bg-white/6 p-3 text-sm">
                  <p class="font-semibold">{@last_event.title}</p>
                  <p class="mt-1 text-xs text-stone-400">{@last_event.layer}</p>
                  <p class="mt-2 text-xs leading-5 text-stone-300">{@last_event.detail}</p>
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Message record</h3>
                <div class="rounded-md border border-white/10 bg-white/6 p-3 text-xs">
                  <p class="font-semibold">{@developer_message_inspector.title}</p>
                  <pre class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-stone-950/40 p-2 text-stone-300">{@developer_message_inspector.persisted_record_text}</pre>
                  <pre class="mt-2 max-h-32 overflow-auto whitespace-pre-wrap rounded bg-stone-950/40 p-2 text-stone-300">{@developer_message_inspector.delivery_text}</pre>
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Jido Chat contract</h3>
                <div class="space-y-2">
                  {%for item <- @developer_contract}
                    <div class="rounded-md border border-white/10 bg-white/6 p-3 text-xs">
                      <div class="flex justify-between gap-3">
                        <span>{item.label}</span>
                        <span class="font-semibold text-stone-100">{item.value}</span>
                      </div>
                      <p class="mt-1 leading-5 text-stone-400">{item.detail}</p>
                    </div>
                  {/for}
                </div>
              </section>

              <section>
                <h3 class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-400">Stack path</h3>
                <div class="space-y-2">
                  {%for layer <- @developer_stack}
                    <div class="rounded-md border border-white/10 bg-white/6 p-3 text-xs">
                      <div class="flex justify-between gap-3">
                        <span class="font-semibold">{layer.name}</span>
                        <span class="text-stone-400">{layer.badge}</span>
                      </div>
                      <p class="mt-1 leading-5 text-stone-400">{layer.role}</p>
                    </div>
                  {/for}
                </div>
              </section>
            {/if}
          </div>
        </aside>
      </div>
    {/if}
    """
  end
end
