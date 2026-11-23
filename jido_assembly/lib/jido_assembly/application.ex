defmodule Jido.Assembly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Jido.Assembly.Pilot.configure!()

    children = [
      Jido.AssemblyWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:jido_assembly, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Jido.Assembly.PubSub},
      Jido.AssemblyWeb.Presence,
      Jido.Assembly.Jido,
      {Jido.Assembly.ChatStorage,
       path: Application.get_env(:jido_assembly, :sqlite_path, "data/jido_assembly_v3.sqlite3"),
       mode: Jido.Assembly.Pilot.mode()},
      Jido.Assembly.ChatRuntime,
      Jido.Assembly.Seeds,
      {Task.Supervisor, name: Jido.Assembly.AgentRuns.Tasks},
      Jido.Assembly.AgentRuns,
      Jido.Assembly.ReleaseNotes.Workflow,
      {Jido.Assembly.Bridges, Application.get_env(:jido_assembly, :bridge_options, [])},
      Jido.Assembly.ChatConnections.PendingReplies,
      Jido.Assembly.ChatConnections.DeliveryRetries,
      Jido.AssemblyWeb.RuntimeNotifier,
      Jido.Assembly.Presence.SessionSupervisor,
      Jido.Assembly.Presence,
      Jido.Assembly.PilotSessions,
      Jido.AssemblyWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Jido.Assembly.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Jido.AssemblyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
