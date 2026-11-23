defmodule Jido.AssemblyWeb.ReleaseNotesController do
  use Jido.AssemblyWeb, :controller

  alias Hologram.Runtime.Session
  alias Jido.Assembly.ReleaseNotes

  plug :resolve_person

  def index(conn, params) do
    person = conn.assigns.release_person
    view = if params["view"] in ["inbox", "board"], do: params["view"], else: "thread"
    runs = ReleaseNotes.runs(person)

    render(conn, :index,
      page_title: "Release notes · Assembly",
      person: person,
      view: view,
      runs: runs,
      inbox: ReleaseNotes.inbox(runs, person),
      demo_switcher: conn.assigns.release_demo
    )
  end

  def submit(conn, params) do
    person = conn.assigns.release_person
    path = ~p"/release-notes?#{[as: person]}"

    case ReleaseNotes.submit(person, params) do
      {:ok, message} ->
        anchor =
          if params["operation"] == "request",
            do: ReleaseNotes.decision_anchor(message.id),
            else: ReleaseNotes.message_anchor(message.id)

        conn |> put_status(:see_other) |> redirect(to: path <> "#" <> anchor)

      {:error, reason} ->
        anchor = fragment_for(params["target"])

        conn
        |> put_flash(:error, ReleaseNotes.error_to_string(reason))
        |> put_status(:see_other)
        |> redirect(to: path <> anchor)
    end
  end

  defp resolve_person(conn, _opts) do
    case Session.get_user_id(conn) do
      nil ->
        conn
        |> assign(:release_person, ReleaseNotes.viewer(conn.params["as"]))
        |> assign(:release_demo, true)

      user_id ->
        case ReleaseNotes.person_for(user_id) do
          {:ok, person} ->
            conn |> assign(:release_person, person) |> assign(:release_demo, false)

          :error ->
            conn |> send_resp(:forbidden, "You do not have access to release reviews.") |> halt()
        end
    end
  end

  defp fragment_for(target) when is_binary(target),
    do: "#" <> URI.encode(target, &URI.char_unreserved?/1)

  defp fragment_for(_target), do: ""
end
