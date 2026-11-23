defmodule Jido.AssemblyWeb.PilotAccess do
  @moduledoc "Applies the pilot session boundary before either web router runs."

  import Plug.Conn
  alias Hologram.Runtime.Session
  alias Jido.Assembly.{Pilot, PilotSessions}

  def init(opts), do: opts

  def chat_params(params) do
    for key <- ["room", "message"],
        value = params[key],
        is_binary(value),
        byte_size(value) in 1..255,
        Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, value),
        into: %{},
        do: {key, value}
  end

  def chat_path(params), do: path_with_params("/", chat_params(params))

  def call(conn, _opts) do
    if Pilot.enabled?() do
      conn
      |> fetch_session()
      |> put_resp_header("cache-control", "no-store")
      |> authorize()
    else
      conn
    end
  end

  defp authorize(%{request_path: "/health", method: "GET"} = conn), do: conn

  defp authorize(%{request_path: "/sign-in", method: method} = conn)
       when method in ["GET", "POST"],
       do: conn

  defp authorize(%{request_path: path} = conn)
       when path in ["/release-notes", "/hologram/websocket"],
       do: reply(conn, 404, "Not found")

  defp authorize(conn) do
    id = Session.get_session_id(conn)
    user = Session.get_user_id(conn)

    cond do
      not is_binary(user) or not is_binary(id) ->
        deny(conn)

      conn.request_path == "/hologram/sse" ->
        if PilotSessions.attach_stream(id, user), do: conn, else: deny(conn)

      PilotSessions.valid?(id, user) ->
        conn

      true ->
        deny(conn)
    end
  end

  defp deny(%{method: "GET", request_path: "/"} = conn) do
    conn = fetch_query_params(conn)
    location = path_with_params("/sign-in", chat_params(conn.query_params))
    conn |> Phoenix.Controller.redirect(to: location) |> halt()
  end

  defp deny(%{method: "GET", request_path: "/sign-out"} = conn) do
    conn |> Phoenix.Controller.redirect(to: "/sign-in") |> halt()
  end

  defp deny(conn), do: reply(conn, 401, "Sign in to continue")

  defp path_with_params(path, params) when map_size(params) == 0, do: path
  defp path_with_params(path, params), do: path <> "?" <> URI.encode_query(params)

  defp reply(conn, status, body), do: conn |> send_resp(status, body) |> halt()
end
