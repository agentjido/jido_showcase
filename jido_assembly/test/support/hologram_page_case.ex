defmodule Jido.Assembly.HologramPageCase do
  @moduledoc """
  Helpers for testing Hologram pages at the action/command boundary.

  Hologram actions and commands are plain Elixir functions. These helpers let
  tests initialize a page and assert on the returned component/server structs
  without starting a browser or Hologram's feature-test runtime.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Hologram.Component
      alias Hologram.Server

      import Jido.Assembly.HologramPageCase
    end
  end

  def init_page(page_module, params \\ %{}, server_opts \\ []) do
    server =
      struct!(
        Hologram.Server,
        Keyword.merge(
          [
            cid: "page",
            instance_id: "test-instance",
            session_id: "test-session"
          ],
          server_opts
        )
      )

    case page_module.init(params, %Hologram.Component{}, server) do
      {%Hologram.Component{} = component, %Hologram.Server{} = server} -> {component, server}
      %Hologram.Component{} = component -> {component, server}
      %Hologram.Server{} = server -> {%Hologram.Component{}, server}
    end
  end

  def put_page_state(%Hologram.Component{} = component, key, value) do
    %{component | state: Map.put(component.state, key, value)}
  end
end
