defmodule Jido.AssemblyWeb.PageControllerTest do
  use Jido.AssemblyWeb.ConnCase

  test "GET /health", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
