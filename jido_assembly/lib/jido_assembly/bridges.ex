defmodule Jido.Assembly.Bridges do
  @moduledoc """
  Durable Jido Chat V3 provider declarations and Room bindings for Assembly.

  Credentials stay in the host environment. Durable declarations contain only
  environment references. Missing credentials keep each provider in demo mode.
  """

  use GenServer

  require Logger

  alias Jido.Assembly.{ChatRuntime, Seeds}
  alias Jido.Chat.Runtime.Bridge.Binding

  @connectors [
    %{
      id: "telegram",
      name: "Telegram",
      short_name: "TG",
      channel: :telegram,
      module: Jido.Chat.Telegram.Adapter,
      account_id: "assembly:telegram",
      definition_key: "assembly.telegram.v1",
      token_env: "TELEGRAM_BOT_TOKEN",
      target_envs: ["TELEGRAM_TEST_CHAT_ID", "TELEGRAM_BRIDGE_CHAT_ID"],
      surface: "bot chat polling"
    },
    %{
      id: "discord",
      name: "Discord",
      short_name: "DC",
      channel: :discord,
      module: Jido.Chat.Discord.Adapter,
      account_id: "assembly:discord",
      definition_key: "assembly.discord.v1",
      token_env: "DISCORD_BOT_TOKEN",
      target_envs: ["DISCORD_TEST_CHANNEL_ID", "DISCORD_BRIDGE_CHANNEL_ID"],
      surface: "gateway and channel messages"
    }
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, %{setup: :pending, snapshot: nil, opts: opts}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    case ensure_ops_room!(Seeds.default_room_id(), state.opts) do
      {:ok, snapshot} ->
        {:noreply, %{state | setup: :ready, snapshot: snapshot}}

      {:error, reason} ->
        Logger.warning("Assembly provider setup is unavailable: #{inspect(reason)}")
        {:noreply, %{state | setup: {:error, reason}}}
    end
  end

  @doc "Returns the last automatic provider setup result."
  def setup_status, do: GenServer.call(__MODULE__, :setup_status)

  @impl true
  def handle_call(:setup_status, _from, state), do: {:reply, state.setup, state}

  def connectors, do: @connectors
  def connector_ids, do: Enum.map(@connectors, & &1.id)
  def bridge_ids, do: Enum.map(@connectors, & &1.account_id)

  def bridge_id_for(id) do
    case Enum.find(@connectors, &(&1.id == to_string(id))) do
      nil -> nil
      connector -> connector.account_id
    end
  end

  def channel_for(id) do
    case Enum.find(@connectors, &(&1.id == to_string(id))) do
      nil -> nil
      connector -> connector.channel
    end
  end

  def ensure_ops_room!(room_id \\ Seeds.default_room_id(), opts \\ []) do
    env_fun = Keyword.get(opts, :env_fun, &System.get_env/1)
    results = Enum.map(@connectors, &ensure_connector(room_id, &1, env_fun, opts))

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Map.put(snapshot(room_id, env_fun: env_fun), :setup_results, results)}
      {:error, reason} -> {:error, reason}
    end
  end

  def snapshot(room_id \\ Seeds.default_room_id(), opts \\ []) do
    env_fun = Keyword.get(opts, :env_fun, &System.get_env/1)
    connectors = Enum.map(@connectors, &connector_status(&1, room_id, env_fun))
    live_count = Enum.count(connectors, &(&1.mode == "live"))

    %{
      connectors: connectors,
      live_count: live_count,
      demo_count: Enum.count(connectors) - live_count,
      routing_policy: %{
        delivery_mode: "broadcast",
        failover_policy: "durable_outbox",
        fallback_order: bridge_ids()
      },
      headline: connector_headline(connectors),
      llm: llm_status(env_fun)
    }
  end

  defp ensure_connector(room_id, connector, env_fun, opts) do
    with {:ok, declaration} <- ensure_declaration(connector),
         {:ok, binding} <- configure_binding(room_id, connector, env_fun),
         :ok <- configure_lifecycle(connector, env_fun, opts) do
      {:ok,
       %{
         connector: connector.id,
         declaration_revision: declaration.revision,
         binding_id: binding && Binding.mapping_name(binding),
         mode: if(live_ready?(connector, env_fun), do: :live, else: :demo)
       }}
    end
  end

  defp ensure_declaration(connector) do
    attrs = %{
      account_id: connector.account_id,
      desired: :stopped,
      secret_refs: %{"token" => connector.token_env},
      settings: %{},
      metadata: %{
        "provider" => connector.id,
        "source" => "jido_assembly",
        "showcase" => "ops_workflow"
      }
    }

    case ChatRuntime.get_connection_declaration(connector.account_id) do
      {:ok, nil} ->
        case ChatRuntime.provision_connection(connector.definition_key, attrs) do
          {:ok, %{declaration: declaration}} -> {:ok, declaration}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{definition_key: definition_key}} when definition_key != connector.definition_key ->
        {:error, :connection_definition_conflict}

      {:ok, declaration} ->
        update_declaration(declaration, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_declaration(declaration, attrs) do
    update = Map.take(attrs, [:secret_refs, :settings, :metadata])

    if Map.take(declaration, Map.keys(update)) == update do
      {:ok, declaration}
    else
      case ChatRuntime.update_connection_declaration(
             declaration.account_id,
             declaration.revision,
             update
           ) do
        {:ok, %{declaration: next}} -> {:ok, next}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp configure_binding(room_id, connector, env_fun) do
    if live_ready?(connector, env_fun) do
      target = target(connector, env_fun)

      with {:ok, bindings} <- ChatRuntime.list_bridge_bindings(connector.account_id),
           :ok <- disable_other_bindings(connector.account_id, bindings, target),
           do: ensure_binding(room_id, connector, target, bindings)
    else
      with {:ok, bindings} <- ChatRuntime.list_bridge_bindings(connector.account_id),
           :ok <- disable_other_bindings(connector.account_id, bindings, nil) do
        {:ok, nil}
      end
    end
  end

  defp disable_other_bindings(account_id, bindings, target) do
    bindings
    |> Enum.filter(&(&1.enabled and &1.external_room_id != target))
    |> Enum.reduce_while(:ok, fn binding, :ok ->
      case ChatRuntime.deprovision_bridge_binding(account_id, binding.external_room_id) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_binding(room_id, connector, target, bindings) do
    attrs = %{
      account_id: connector.account_id,
      room_id: room_id,
      external_room_id: target,
      direction: :both,
      enabled: true,
      metadata: %{"provider" => connector.id, "source" => "jido_assembly"}
    }

    case Enum.find(bindings, &(&1.external_room_id == target)) do
      nil ->
        case ChatRuntime.create_bridge_binding(attrs) do
          {:ok, %{binding: binding}} -> {:ok, binding}
          {:error, reason} -> {:error, reason}
        end

      binding ->
        update = Map.take(attrs, [:room_id, :direction, :enabled, :metadata])

        if Map.take(binding, Map.keys(update)) == update do
          {:ok, binding}
        else
          case ChatRuntime.update_bridge_binding(
                 connector.account_id,
                 target,
                 binding.revision,
                 update
               ) do
            {:ok, %{binding: next}} -> {:ok, next}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp configure_lifecycle(connector, env_fun, opts) do
    activate? = Keyword.get(opts, :listener_mode, :live) != :passive

    result =
      if live_ready?(connector, env_fun) and activate? do
        ChatRuntime.start_managed_connection(connector.account_id)
      else
        ChatRuntime.stop_managed_connection(connector.account_id)
      end

    case result do
      {:ok, _status} -> :ok
      {:error, {:lifecycle_failed, status}} -> {:error, {:provider_lifecycle_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connector_status(connector, room_id, env_fun) do
    loaded? = Code.ensure_loaded?(connector.module)
    missing_env = missing_env(connector, env_fun)
    target = target(connector, env_fun)
    declaration = declaration(connector.account_id)
    binding = target && binding(connector.account_id, target)
    runtime = managed_status(connector.account_id)
    mode = connector_mode(loaded?, missing_env, declaration, binding)

    %{
      id: connector.id,
      name: connector.name,
      short_name: connector.short_name,
      surface: connector.surface,
      channel: Atom.to_string(connector.channel),
      bridge_id: connector.account_id,
      adapter_module: inspect(connector.module),
      loaded: loaded?,
      mode: Atom.to_string(mode),
      status: connector_status_text(mode, runtime),
      missing_env: missing_env,
      target: target || "",
      target_label: target || "demo only",
      target_envs: connector.target_envs,
      binding_id: binding && Binding.mapping_name(binding),
      listener_count: listener_count(runtime),
      listener_count_label: Integer.to_string(listener_count(runtime)),
      last_ingress_at: "",
      last_outbound_at: "",
      last_error: runtime_error(runtime),
      room_id: room_id || ""
    }
  end

  defp declaration(account_id) do
    case ChatRuntime.get_connection_declaration(account_id) do
      {:ok, declaration} -> declaration
      {:error, _reason} -> nil
    end
  end

  defp binding(account_id, external_room_id) do
    case ChatRuntime.get_bridge_binding(account_id, external_room_id) do
      {:ok, binding} -> binding
      {:error, _reason} -> nil
    end
  end

  defp managed_status(account_id) do
    case ChatRuntime.managed_connection_status(account_id) do
      {:ok, status} -> status
      {:error, _reason} -> nil
    end
  end

  defp connector_mode(false, _missing, _declaration, _binding), do: :unavailable

  defp connector_mode(true, [], %{desired: desired}, %{enabled: true})
       when desired in [:running, :stopped],
       do: :live

  defp connector_mode(true, _missing, _declaration, _binding), do: :demo

  defp connector_status_text(:unavailable, _runtime), do: "package missing"
  defp connector_status_text(:demo, _runtime), do: "demo"
  defp connector_status_text(:live, %{state: :running}), do: "live"
  defp connector_status_text(:live, %{state: :error}), do: "live with errors"
  defp connector_status_text(:live, _runtime), do: "configured"

  defp listener_count(%{state: :running}), do: 1
  defp listener_count(_runtime), do: 0

  defp runtime_error(%{error: nil}), do: nil
  defp runtime_error(%{error: error}), do: inspect(error)
  defp runtime_error(_runtime), do: nil

  defp missing_env(connector, env_fun) do
    []
    |> maybe_missing(connector.token_env, env_fun)
    |> maybe_missing_target(connector, env_fun)
  end

  defp maybe_missing(missing, name, env_fun) do
    if present?(env_fun.(name)), do: missing, else: missing ++ [name]
  end

  defp maybe_missing_target(missing, connector, env_fun) do
    if present?(target(connector, env_fun)) do
      missing
    else
      missing ++ [Enum.join(connector.target_envs, " or ")]
    end
  end

  defp live_ready?(connector, env_fun), do: missing_env(connector, env_fun) == []

  defp target(connector, env_fun) do
    Enum.find_value(connector.target_envs, fn name -> present(env_fun.(name)) end)
  end

  defp llm_status(env_fun) do
    if present?(env_fun.("ANTHROPIC_API_KEY")) do
      %{mode: "live", status: "ready", missing_env: []}
    else
      %{
        mode: "disabled",
        status: "ANTHROPIC_API_KEY required",
        missing_env: ["ANTHROPIC_API_KEY"]
      }
    end
  end

  defp connector_headline(connectors) do
    case connectors |> Enum.filter(&(&1.mode == "live")) |> Enum.map(& &1.name) do
      [] -> "Demo connectors"
      [one] -> "#{one} live"
      many -> Enum.join(many, " + ") <> " live"
    end
  end

  defp present?(value), do: not is_nil(present(value))
  defp present(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp present(_value), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
