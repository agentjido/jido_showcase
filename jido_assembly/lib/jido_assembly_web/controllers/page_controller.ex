defmodule Jido.AssemblyWeb.PageController do
  use Jido.AssemblyWeb, :controller

  def home(conn, _params) do
    if Jido.Assembly.Pilot.enabled?(), do: text(conn, "ok"), else: render(conn, :home)
  end
end
