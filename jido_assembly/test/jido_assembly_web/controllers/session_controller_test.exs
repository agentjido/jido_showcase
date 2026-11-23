defmodule Jido.AssemblyWeb.SessionControllerTest do
  use Jido.AssemblyWeb.ConnCase

  alias Hologram.Runtime.Session
  alias Jido.Assembly.{Pilot, PilotSessions}

  @key Base.url_encode64(<<1::256>>, padding: false)
  @account %{
    "id" => "user:ada",
    "name" => "Ada Turner",
    "key_sha256" => Base.encode16(:crypto.hash(:sha256, @key))
  }

  setup do
    {:ok, roster} = Pilot.parse_roster(Jason.encode!([@account]))
    Application.put_env(:jido_assembly, :pilot_accounts, roster)
    on_exit(fn -> Application.delete_env(:jido_assembly, :pilot_accounts) end)
    :ok
  end

  test "a visitor sees the sign-in page and the health check", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/sign-in"
    sign_in = get(build_conn(), ~p"/sign-in")
    assert html_response(sign_in, 200) =~ "Sign in to Assembly"
    assert get_resp_header(sign_in, "cache-control") == ["no-store"]
    assert text_response(get(build_conn(), ~p"/health"), 200) == "ok"
  end

  test "a visitor cannot reach command, identity, or stream routes", %{conn: conn} do
    for {method, path} <- [
          {:post, "/hologram/command"},
          {:post, "/hologram/page/Jido.Assembly.Pages.Assembly"},
          {:get, "/hologram/identity-tag"},
          {:post, "/hologram/sse/handshake"},
          {:get, "/hologram/sse"}
        ] do
      assert response(dispatch(conn, @endpoint, method, path), 401) == "Sign in to continue"
    end

    assert response(get(conn, "/hologram/websocket"), 404) == "Not found"
    assert response(get(conn, ~p"/release-notes"), 404) == "Not found"
  end

  test "an incorrect key does not create a session", %{conn: conn} do
    conn = post(conn, ~p"/sign-in", %{user_id: "user:ada", access_key: "wrong"})
    assert html_response(conn, 401) =~ "The user ID or access key is incorrect."
    assert Session.get_user_id(conn) == nil
  end

  test "the request logger filters access keys" do
    assert Phoenix.Logger.filter_values(%{"access_key" => @key, "user_id" => "user:ada"}) ==
             %{"access_key" => "[FILTERED]", "user_id" => "user:ada"}
  end

  test "sign-in requires the browser's CSRF token", %{conn: conn} do
    conn = put_private(conn, :plug_skip_csrf_protection, false)

    assert_error_sent 403, fn ->
      post(conn, ~p"/sign-in", %{user_id: "user:ada", access_key: @key})
    end
  end

  test "sign-in preserves a message link and ignores unrelated redirects", %{conn: conn} do
    deep_link = "/?room=room%3Ageneral&message=note-1&return_to=https%3A%2F%2Fexample.test"
    location = redirected_to(get(conn, deep_link))
    assert URI.parse(location).path == "/sign-in"

    assert URI.decode_query(URI.parse(location).query) == %{
             "room" => "room:general",
             "message" => "note-1"
           }

    signed_in =
      post(build_conn(), ~p"/sign-in", %{
        user_id: "user:ada",
        access_key: @key,
        room: "room:general",
        message: "note-1",
        return_to: "//example.test"
      })

    target = URI.parse(redirected_to(signed_in, 303))
    assert target.path == "/"
    assert URI.decode_query(target.query) == %{"room" => "room:general", "message" => "note-1"}
    :ok = PilotSessions.revoke(Session.get_session_id(signed_in))
  end

  test "sign-in renews the identity, and sign-out revokes the previous cookie", %{conn: conn} do
    prior = "pilot-test-old"
    :ok = PilotSessions.open(prior, "user:ada")

    signed_in =
      conn
      |> init_test_session(%{"hologram_session_id" => prior, "hologram_user_id" => "user:ada"})
      |> post(~p"/sign-in", %{user_id: "user:ada", access_key: @key})

    assert redirected_to(signed_in, 303) == "/"
    assert Session.get_user_id(signed_in) == "user:ada"
    session_id = Session.get_session_id(signed_in)
    assert session_id != prior
    refute PilotSessions.valid?(prior, "user:ada")
    assert PilotSessions.valid?(session_id, "user:ada")

    assert html_response(get(recycle(signed_in), ~p"/sign-out"), 200) =~ "Sign out of Assembly?"
    signed_out = post(recycle(signed_in), ~p"/sign-out")
    assert redirected_to(signed_out, 303) == "/sign-in"
    assert redirected_to(get(recycle(signed_in), "/")) == "/sign-in"
  end
end
