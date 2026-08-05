defmodule Jido.AssemblyWeb.PageController do
  use Jido.AssemblyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
