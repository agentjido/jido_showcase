defmodule Jido.AssemblyWeb.SessionController do
  use Jido.AssemblyWeb, :controller

  alias Hologram.Runtime.Session
  alias Jido.Assembly.{Pilot, PilotSessions}
  alias Jido.AssemblyWeb.PilotAccess

  plug :require_pilot

  def new(conn, params), do: render_form(conn, params, nil)

  def create(conn, params) do
    case Pilot.authenticate(params["user_id"], params["access_key"]) do
      {:ok, user_id} ->
        :ok = PilotSessions.revoke(Session.get_session_id(conn))

        conn =
          conn
          |> configure_session(renew: true)
          |> clear_session()
          |> Session.init()
          |> Session.put_user_id(user_id)

        :ok = PilotSessions.open(Session.get_session_id(conn), user_id)
        conn |> put_status(:see_other) |> redirect(to: PilotAccess.chat_path(params))

      :error ->
        conn
        |> put_status(:unauthorized)
        |> render_form(params, "The user ID or access key is incorrect.")
    end
  end

  defp render_form(conn, params, error) do
    render(conn, :new,
      error: error,
      chat_params: PilotAccess.chat_params(params),
      page_title: "Sign in"
    )
  end

  def confirm_delete(conn, _params), do: render(conn, :sign_out, page_title: "Sign out")

  def delete(conn, _params) do
    :ok = PilotSessions.revoke(Session.get_session_id(conn))

    conn
    |> configure_session(drop: true)
    |> put_status(:see_other)
    |> redirect(to: "/sign-in")
  end

  defp require_pilot(conn, _opts) do
    if Pilot.enabled?(), do: conn, else: conn |> send_resp(:not_found, "Not found") |> halt()
  end
end
