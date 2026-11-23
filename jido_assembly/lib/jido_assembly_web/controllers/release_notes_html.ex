defmodule Jido.AssemblyWeb.ReleaseNotesHTML do
  use Jido.AssemblyWeb, :html

  alias Jido.Assembly.ReleaseNotes

  embed_templates "release_notes_html/*"

  defp page_path(person, "thread"), do: ~p"/release-notes?#{[as: person]}"
  defp page_path(person, view), do: ~p"/release-notes?#{[as: person, view: view]}"
  defp item_path(person, run), do: page_path(person, "thread") <> "#" <> run.target

  defp change_heading(%{"type" => "draft", "version" => version}),
    do: "Release note · v#{version}"

  defp change_heading(%{"type" => "revision", "version" => version}),
    do: "Release note · v#{version}"

  defp change_heading(%{"type" => "review"}), do: "Review"

  attr :person, :string, required: true
  attr :run, :map, required: true
  attr :operation, :string, required: true

  defp action_fields(assigns) do
    ~H"""
    <input type="hidden" name="as" value={@person} />
    <input type="hidden" name="operation" value={@operation} />
    <input type="hidden" name="root" value={@run.id} />
    <input type="hidden" name="target" value={@run.target} />
    """
  end

  attr :person, :string, required: true
  attr :run, :map, required: true

  defp work_item(assigns) do
    ~H"""
    <a class="release-item" href={item_path(@person, @run)}>
      <strong>{if @run.note,
        do: "Release note · v#{@run.note.data["version"]}",
        else: "Release criteria"}</strong>
      <span class="release-muted">{@run.root.body}</span>
      <span class="release-status" data-status={@run.status}>
        {ReleaseNotes.status_label(@run.status)}
        <%= if @run.assignee do %>
          · {ReleaseNotes.name(@run.assignee)}
        <% end %>
      </span>
    </a>
    """
  end
end
