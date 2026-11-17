defmodule Jido.Assembly.Presence.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
