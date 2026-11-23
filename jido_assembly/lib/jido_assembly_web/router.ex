defmodule Jido.AssemblyWeb.Router do
  use Jido.AssemblyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Jido.AssemblyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Jido.AssemblyWeb do
    pipe_through :browser

    get "/health", PageController, :home
    get "/sign-in", SessionController, :new
    post "/sign-in", SessionController, :create
    get "/sign-out", SessionController, :confirm_delete
    post "/sign-out", SessionController, :delete
    get "/release-notes", ReleaseNotesController, :index
    post "/release-notes", ReleaseNotesController, :submit
  end

  # Other scopes may use custom stacks.
  # scope "/api", Jido.AssemblyWeb do
  #   pipe_through :api
  # end
end
