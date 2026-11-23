defmodule Jido.Assembly.Components.Assembly.ReleaseWork do
  use Hologram.Component

  prop :work, :any
  prop :view, :string
  prop :channels, :list

  def template do
    ~HOLO"""
    <section class="assembly-work-view">
      <header class="assembly-work-head">
        <h1 id="assembly-view-heading" tabindex="-1">{title(@view)}</h1>
        <p>{description(@view)}</p>
      </header>
      {%if @view == "threads"}
        <div class="assembly-work-list">
          {%for channel <- @channels}
            <button type="button" class="assembly-work-item" $click={:select_room, id: channel.id}>
              <strong># {channel.name}</strong>
              <span>{channel.topic}</span>
            </button>
          {/for}
        </div>
      {/if}
      {%if @view == "inbox"}
        <div class="assembly-work-list" aria-label="Assignments">
          {%for item <- inbox(@work)}
            <a href={item.href} data-assembly-release-target={item.message_id} class="assembly-work-item">
              <strong>{item.title}</strong>
              <span class="assembly-room-label">#jido-chat-release</span>
              <span>{item.request}</span>
            </a>
          {/for}
          {%if inbox(@work) == []}
            <p class="assembly-muted">No decisions or reviews are waiting for you.</p>
          {/if}
        </div>
      {/if}
      {%if @view == "board"}
        <div class="assembly-board" aria-label="Release board">
          {%for lane <- lanes(@work)}
            <section class="assembly-lane" data-assembly-release-lane={lane.id}>
              <h2>{lane.label} <span class="assembly-muted">{length(lane.items)}</span></h2>
              {%for item <- lane.items}
                <a href={item.href} data-assembly-release-target={item.message_id} class="assembly-work-item">
                  <strong>{item.title}</strong>
                  <span class="assembly-room-label">#jido-chat-release</span>
                  <span>{item.request}</span>
                  <small class="assembly-status">{item.status_label}</small>
                </a>
              {/for}
              {%if lane.items == []}<p class="assembly-muted">No threads</p>{/if}
            </section>
          {/for}
        </div>
      {/if}
    </section>
    """
  end

  defp title("threads"), do: "Work threads"
  defp title("inbox"), do: "Needs you"
  defp title("board"), do: "Release board"

  defp description("threads"), do: "Open a conversation to see its messages and agent runs."
  defp description("inbox"), do: "Decisions and reviews Triage has handed to you."

  defp description("board"),
    do: "Release threads grouped by status. Open a card to see the exact request."

  defp inbox(nil), do: []
  defp inbox(work), do: work.inbox

  defp lanes(work) do
    groups = [
      {"running", "Open or running", [:starting, :drafting, :cancelled]},
      {"decision", "Needs a decision", [:decision]},
      {"review", "Ready for review", [:review]},
      {"reviewed", "Reviewed", [:reviewed]}
    ]

    board = if work, do: work.board, else: []

    Enum.map(groups, fn {id, label, statuses} ->
      items =
        for lane <- board, lane.status in statuses, item <- lane.items do
          Map.put(item, :status_label, lane.label)
        end

      %{id: id, label: label, items: items}
    end)
  end
end
