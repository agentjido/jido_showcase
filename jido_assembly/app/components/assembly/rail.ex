defmodule Jido.Assembly.Components.Assembly.Rail do
  use Hologram.Component

  prop :current_user, :map
  prop :rail_target, :string

  def template do
    ~HOLO"""
    <aside class="hidden flex-col items-center gap-3 border-r border-white/8 bg-[var(--assembly-rail)] px-3 py-4 text-stone-200 md:flex">
      <button
        aria-label="Open workspace home"
        class="grid size-11 place-items-center rounded-lg bg-[var(--assembly-accent)] text-base font-black text-stone-950 shadow-sm transition hover:bg-[var(--assembly-accent-strong)] hover:text-stone-100"
        type="button"
        title="Workspace home"
        $click="rail_workspace"
      >
        JA
      </button>
      <button
        aria-label="Open channels"
        class="grid size-10 place-items-center rounded-md transition {if @rail_target == "channels" do "bg-white/18 text-white" else "bg-white/8 text-stone-200 hover:bg-white/12" end}"
        type="button"
        title="Channels"
        $click="rail_channels"
      >
        <span class="hero-chat-bubble-left-right size-5"></span>
      </button>
      <button
        aria-label="Open direct messages"
        class="grid size-10 place-items-center rounded-md transition {if @rail_target == "direct_messages" do "bg-white/18 text-white" else "bg-white/8 text-stone-200 hover:bg-white/12" end}"
        type="button"
        title="Direct messages"
        $click="rail_direct_messages"
      >
        <span class="hero-at-symbol size-5"></span>
      </button>
      <button
        aria-label="Focus search"
        class="grid size-10 place-items-center rounded-md transition {if @rail_target == "search" do "bg-white/18 text-white" else "bg-white/8 text-stone-200 hover:bg-white/12" end}"
        type="button"
        title="Search"
        $click="rail_search"
      >
        <span class="hero-magnifying-glass size-5"></span>
      </button>
      <button
        aria-label="Open demo user switcher"
        class="mt-auto grid size-10 place-items-center rounded-md border text-xs font-semibold transition {if @rail_target == "users" do "border-[var(--assembly-accent)] bg-[var(--assembly-accent)] text-stone-950" else "border-white/10 bg-white/6 text-stone-300 hover:bg-white/10" end}"
        type="button"
        title="Demo user"
        $click="rail_users"
      >
        {@current_user.initials}
      </button>
    </aside>
    """
  end
end
