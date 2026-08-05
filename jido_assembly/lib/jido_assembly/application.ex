defmodule Jido.Assembly.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    configure_adapter_env()

    children = [
      Jido.AssemblyWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:jido_assembly, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Jido.Assembly.PubSub},
      Jido.Assembly.Jido,
      Jido.AssemblyWeb.Presence,
      {Jido.Assembly.Messaging,
       persistence_opts: [
         path: Application.get_env(:jido_assembly, :sqlite_path, "data/jido_assembly.sqlite3")
       ]},
      Jido.Assembly.Seeds,
      Jido.AssemblyWeb.MessagingNotifier,
      Jido.Assembly.Presence,
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

  defp configure_adapter_env do
    put_env_from_system(:jido_chat_telegram, :telegram_bot_token, "TELEGRAM_BOT_TOKEN")
    put_env_from_system(:nostrum, :token, "DISCORD_BOT_TOKEN")
    put_env_from_system(:jido_chat_discord, :discord_bot_token, "DISCORD_BOT_TOKEN")
    put_env_from_system(:jido_chat_discord, :discord_public_key, "DISCORD_PUBLIC_KEY")

    if start_discord_gateway?() do
      Application.put_env(:nostrum, :ffmpeg, nil)
      Application.put_env(:nostrum, :youtubedl, nil)
      Application.put_env(:nostrum, :streamlink, nil)

      Application.put_env(:nostrum, :gateway_intents, [
        :guilds,
        :guild_messages,
        :message_content,
        :direct_messages
      ])

      case Application.ensure_all_started(:nostrum) do
        {:ok, _apps} ->
          :ok

        {:error, reason} ->
          Logger.warning("Discord gateway runtime did not start: #{inspect(reason)}")
      end
    end
  end

  defp put_env_from_system(app, key, env_key) do
    case System.get_env(env_key) do
      value when is_binary(value) and value != "" -> Application.put_env(app, key, value)
      _missing -> :ok
    end
  end

  defp start_discord_gateway? do
    Application.get_env(:jido_assembly, :start_discord_gateway, true) and
      present_env?("DISCORD_BOT_TOKEN")
  end

  defp present_env?(env_key) do
    case System.get_env(env_key) do
      value when is_binary(value) -> String.trim(value) != ""
      _missing -> false
    end
  end
end
