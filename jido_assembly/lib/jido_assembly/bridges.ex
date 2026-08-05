defmodule Jido.Assembly.Bridges do
  @moduledoc """
  Optional live connector setup for the Assembly ops workflow showcase.

  Assembly does not keep app-specific bridge tables. This module derives
  connector state from environment variables and writes directly to
  `Jido.Assembly.Messaging` bridge configs, room bindings, routing policies,
  and runtime bridge status.
  """

  require Logger

  alias Jido.Assembly.{Messaging, Seeds}

  @connectors [
    %{
      id: "telegram",
      name: "Telegram",
      short_name: "TG",
      channel: :telegram,
      module: Jido.Chat.Telegram.Adapter,
      bridge_id: "assembly:telegram",
      token_env: "TELEGRAM_BOT_TOKEN",
      target_envs: ["TELEGRAM_TEST_CHAT_ID", "TELEGRAM_BRIDGE_CHAT_ID"],
      surface: "bot chat polling",
      ingress: %{
        "mode" => "polling",
        "timeout_s" => 2,
        "poll_interval_ms" => 1_000,
        "max_backoff_ms" => 5_000,
        "allowed_updates" => ["message", "edited_message", "channel_post", "edited_channel_post"]
      },
      config: %{"bot_token_env" => "TELEGRAM_BOT_TOKEN"}
    },
    %{
      id: "discord",
      name: "Discord",
      short_name: "DC",
      channel: :discord,
      module: Jido.Chat.Discord.Adapter,
      bridge_id: "assembly:discord",
      token_env: "DISCORD_BOT_TOKEN",
      target_envs: ["DISCORD_TEST_CHANNEL_ID", "DISCORD_BRIDGE_CHANNEL_ID"],
      surface: "gateway and channel messages",
      ingress: %{
        "mode" => "gateway",
        "source" => "nostrum",
        "poll_interval_ms" => 250,
        "max_backoff_ms" => 5_000
      },
      config: %{
        "bot_token_env" => "DISCORD_BOT_TOKEN",
        "public_key_env" => "DISCORD_PUBLIC_KEY"
      }
    }
  ]

  def connectors, do: @connectors

  def connector_ids, do: Enum.map(@connectors, & &1.id)

  def bridge_ids, do: Enum.map(@connectors, & &1.bridge_id)

  def bridge_id_for(id) do
    @connectors
    |> Enum.find(&(&1.id == to_string(id)))
    |> case do
      nil -> nil
      connector -> connector.bridge_id
    end
  end

  def channel_for(id) do
    @connectors
    |> Enum.find(&(&1.id == to_string(id)))
    |> case do
      nil -> nil
      connector -> connector.channel
    end
  end

  def ensure_ops_room!(room_id \\ Seeds.default_room_id(), opts \\ []) do
    env_fun = Keyword.get(opts, :env_fun, &System.get_env/1)

    ensure_broadcast_policy(room_id)

    results =
      Enum.map(@connectors, fn connector ->
        ensure_connector(room_id, connector, env_fun, opts)
      end)

    if Keyword.get(opts, :reconcile?, true) do
      safe_reconcile()
    end

    {:ok, Map.put(snapshot(room_id, env_fun: env_fun), :setup_results, results)}
  end

  def snapshot(room_id \\ Seeds.default_room_id(), opts \\ []) do
    env_fun = Keyword.get(opts, :env_fun, &System.get_env/1)
    connectors = Enum.map(@connectors, &connector_status(&1, room_id, env_fun))
    live_count = Enum.count(connectors, &(&1.mode == "live"))

    %{
      connectors: connectors,
      live_count: live_count,
      demo_count: Enum.count(connectors) - live_count,
      routing_policy: routing_policy_view(room_id),
      headline: connector_headline(connectors),
      llm: llm_status()
    }
  end

  def route_outbound(room_id, text, opts \\ []) do
    room_id = to_string(room_id)
    text = to_string(text)

    case Messaging.resolve_outbound_routes(room_id) do
      {:ok, []} ->
        :no_routes

      {:ok, _routes} ->
        Messaging.route_outbound(room_id, text, opts)

      {:error, _reason} = error ->
        error
    end
  end

  def persist_delivery_result(message, delivery_result) do
    message = annotate_delivery_result(message, delivery_result)

    case Messaging.save_message_struct(message) do
      {:ok, saved_message} ->
        saved_message

      {:error, reason} ->
        Logger.warning("Assembly delivery metadata update failed: #{inspect(reason)}")
        message
    end
  end

  def annotate_delivery_result(message, delivery_result) do
    metadata =
      (message.metadata || %{})
      |> Map.merge(delivery_metadata(delivery_result))

    %{
      message
      | status: delivery_message_status(message.status, delivery_result),
        metadata: metadata,
        updated_at: DateTime.utc_now(:second)
    }
  end

  def delivery_metadata({:ok, summary}), do: summary_metadata(summary, "delivered")

  def delivery_metadata({:error, {:delivery_failed, summary}}) do
    summary
    |> summary_metadata("delivery_failed")
    |> Map.put("delivery_error", inspect(:delivery_failed))
  end

  def delivery_metadata({:error, reason}) do
    %{
      "route_decision" => "delivery_error",
      "delivery_error" => inspect(reason),
      "attempted" => 0,
      "delivered" => 0,
      "failed" => 1
    }
  end

  def delivery_metadata(:no_routes) do
    %{
      "route_decision" => "no_routes",
      "attempted" => 0,
      "delivered" => 0,
      "failed" => 0
    }
  end

  def delivery_metadata(:local_only) do
    %{
      "route_decision" => "local_only",
      "attempted" => 0,
      "delivered" => 0,
      "failed" => 0
    }
  end

  defp ensure_connector(room_id, connector, env_fun, opts) do
    if live_ready?(connector, env_fun) do
      target = target(connector, env_fun)

      with {:ok, _bridge} <- put_live_bridge_config(connector, target, opts),
           {:ok, binding} <- ensure_binding(room_id, connector, target) do
        {:ok, %{connector: connector.id, binding_id: binding.id, target: target}}
      end
    else
      disable_bridge(connector)
      cleanup_bindings(room_id, connector)
      {:ok, %{connector: connector.id, mode: :demo}}
    end
  end

  defp put_live_bridge_config(connector, target, opts) do
    opts =
      %{
        "provider" => connector.id,
        "surface" => connector.surface,
        "target" => target,
        "target_envs" => connector.target_envs,
        "config" => Map.put(connector.config, "target", target),
        "ingress" => ingress_config(connector, opts),
        "metadata" => %{
          "source" => "jido_assembly",
          "showcase" => "ops_workflow"
        }
      }

    Messaging.put_bridge_config(%{
      id: connector.bridge_id,
      adapter_module: connector.module,
      credentials: %{},
      opts: opts,
      enabled: true
    })
  end

  defp ingress_config(connector, opts) do
    case Keyword.get(opts, :listener_mode, :live) do
      :passive -> %{"mode" => "webhook", "source" => "jido_assembly.passive"}
      _live -> connector.ingress
    end
  end

  defp safe_reconcile do
    Jido.Messaging.BridgeSupervisor.reconcile(Messaging)
  catch
    :exit, reason ->
      Logger.warning("Assembly bridge reconcile skipped after connector exit: #{inspect(reason)}")
      :ok
  end

  defp disable_bridge(connector) do
    case Messaging.get_bridge_config(connector.bridge_id) do
      {:ok, bridge} ->
        Messaging.put_bridge_config(%{
          id: bridge.id,
          adapter_module: bridge.adapter_module,
          credentials: bridge.credentials,
          opts: bridge.opts,
          enabled: false
        })

      {:error, :not_found} ->
        :ok
    end
  end

  defp ensure_binding(room_id, connector, target) do
    cleanup_bindings(room_id, connector, except_target: target)

    case find_binding(room_id, connector, target) do
      nil ->
        Messaging.create_room_binding(room_id, connector.channel, connector.bridge_id, target, %{
          direction: :both,
          enabled: true
        })

      binding ->
        {:ok, binding}
    end
  end

  defp cleanup_bindings(room_id, connector, opts \\ []) do
    except_target = Keyword.get(opts, :except_target)

    room_id
    |> bindings_for_room()
    |> Enum.filter(fn binding ->
      binding.channel == connector.channel and binding.bridge_id == connector.bridge_id and
        binding.external_room_id != except_target
    end)
    |> Enum.each(fn binding ->
      _ = Messaging.delete_room_binding(binding.id)
    end)

    :ok
  end

  defp find_binding(room_id, connector, target) do
    room_id
    |> bindings_for_room()
    |> Enum.find(fn binding ->
      binding.channel == connector.channel and binding.bridge_id == connector.bridge_id and
        binding.external_room_id == target and binding.enabled
    end)
  end

  defp bindings_for_room(room_id) do
    case Messaging.list_room_bindings(room_id) do
      {:ok, bindings} -> bindings
      {:error, _reason} -> []
    end
  end

  defp ensure_broadcast_policy(room_id) do
    Messaging.put_routing_policy(room_id, %{
      delivery_mode: :broadcast,
      failover_policy: :broadcast,
      dedupe_scope: :message_id,
      fallback_order: bridge_ids(),
      metadata: %{
        "source" => "jido_assembly",
        "showcase" => "ops_workflow",
        "description" => "Broadcast local ops-room messages to every configured live connector."
      }
    })
  end

  defp connector_status(connector, room_id, env_fun) do
    loaded? = Code.ensure_loaded?(connector.module)
    missing_env = missing_env(connector, env_fun)
    target = target(connector, env_fun)
    config = bridge_config(connector.bridge_id)
    binding = target && find_binding(room_id, connector, target)
    runtime = bridge_status(connector.bridge_id)
    mode = connector_mode(loaded?, missing_env, config, binding)

    %{
      id: connector.id,
      name: connector.name,
      short_name: connector.short_name,
      surface: connector.surface,
      channel: Atom.to_string(connector.channel),
      bridge_id: connector.bridge_id,
      adapter_module: inspect(connector.module),
      loaded: loaded?,
      mode: Atom.to_string(mode),
      status: connector_status_text(mode, runtime),
      missing_env: missing_env,
      target: target || "",
      target_label: target || "demo only",
      target_envs: connector.target_envs,
      binding_id: binding && binding.id,
      listener_count: runtime && runtime.listener_count,
      listener_count_label: runtime_listener_count(runtime),
      last_ingress_at: format_time(runtime && runtime.last_ingress_at),
      last_outbound_at: format_time(runtime && runtime.last_outbound_at),
      last_error: runtime && inspect(runtime.last_error)
    }
  end

  defp connector_mode(false, _missing_env, _config, _binding), do: :unavailable
  defp connector_mode(true, [], %{enabled: true}, binding) when not is_nil(binding), do: :live
  defp connector_mode(true, _missing_env, _config, _binding), do: :demo

  defp connector_status_text(:live, nil), do: "live pending"
  defp connector_status_text(:live, %{last_error: nil}), do: "live"

  defp connector_status_text(:live, %{last_error: error}) when not is_nil(error),
    do: "live with errors"

  defp connector_status_text(:demo, _runtime), do: "demo"
  defp connector_status_text(:unavailable, _runtime), do: "package missing"

  defp runtime_listener_count(%{listener_count: listener_count})
       when is_integer(listener_count) do
    Integer.to_string(listener_count)
  end

  defp runtime_listener_count(_runtime), do: "0"

  defp bridge_config(bridge_id) do
    case Messaging.get_bridge_config(bridge_id) do
      {:ok, config} -> config
      {:error, :not_found} -> nil
    end
  end

  defp bridge_status(bridge_id) do
    try do
      case Messaging.bridge_status(bridge_id) do
        {:ok, status} -> status
        {:error, _reason} -> nil
      end
    catch
      :exit, _reason -> nil
    end
  end

  defp routing_policy_view(room_id) do
    case Messaging.get_routing_policy(room_id) do
      {:ok, policy} ->
        %{
          delivery_mode: Atom.to_string(policy.delivery_mode),
          failover_policy: Atom.to_string(policy.failover_policy),
          fallback_order: policy.fallback_order
        }

      {:error, :not_found} ->
        %{
          delivery_mode: "best_effort",
          failover_policy: "next_available",
          fallback_order: []
        }
    end
  end

  defp missing_env(connector, env_fun) do
    []
    |> maybe_missing(connector.token_env, env_fun)
    |> maybe_missing_target(connector, env_fun)
  end

  defp maybe_missing(missing, env_key, env_fun) do
    if present?(env_fun.(env_key)), do: missing, else: missing ++ [env_key]
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
    connector.target_envs
    |> Enum.find_value(fn env_key ->
      env_key
      |> env_fun.()
      |> present()
    end)
  end

  defp llm_status do
    if present?(ReqLLM.get_key(:anthropic_api_key)) or
         present?(ReqLLM.get_key("ANTHROPIC_API_KEY")) do
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
    live =
      connectors
      |> Enum.filter(&(&1.mode == "live"))
      |> Enum.map(& &1.name)

    case live do
      [] -> "Demo connectors"
      [one] -> "#{one} live"
      many -> Enum.join(many, " + ") <> " live"
    end
  end

  defp delivery_message_status(_status, {:ok, summary}) do
    delivered = summary_items(summary, :delivered)
    failed = summary_items(summary, :failed)

    cond do
      delivered != [] and failed == [] -> :delivered
      delivered != [] -> :sent
      true -> :failed
    end
  end

  defp delivery_message_status(_status, {:error, _reason}), do: :failed
  defp delivery_message_status(status, :no_routes), do: status
  defp delivery_message_status(status, :local_only), do: status

  defp summary_metadata(summary, route_decision) do
    delivered = summary_items(summary, :delivered)
    failed = summary_items(summary, :failed)

    %{
      "route_decision" => route_decision,
      "attempted" => metadata_value(summary, :attempted) || length(delivered) + length(failed),
      "delivered" => length(delivered),
      "failed" => length(failed),
      "delivered_routes" => Enum.map(delivered, &delivery_success_record/1),
      "failed_routes" => Enum.map(failed, &delivery_failure_record/1)
    }
    |> Map.merge(first_route_metadata(delivered, failed))
  end

  defp summary_items(summary, key) do
    case metadata_value(summary, key) do
      items when is_list(items) -> items
      _other -> []
    end
  end

  defp first_route_metadata(delivered, failed) do
    (List.first(delivered) || List.first(failed))
    |> case do
      nil ->
        %{}

      delivery ->
        delivery
        |> metadata_value(:route)
        |> route_metadata()
    end
  end

  defp delivery_success_record(success) do
    route = metadata_value(success, :route) || %{}
    result = metadata_value(success, :result) || %{}

    %{
      "bridge_id" => route_value(route, :bridge_id),
      "channel" => route_value(route, :channel),
      "external_room_id" => route_value(route, :external_room_id),
      "message_id" => normalize_delivery_value(metadata_value(result, :message_id)),
      "operation" => normalize_delivery_value(metadata_value(result, :operation))
    }
    |> compact_metadata()
  end

  defp delivery_failure_record(failure) do
    route = metadata_value(failure, :route) || %{}

    %{
      "bridge_id" => route_value(route, :bridge_id),
      "channel" => route_value(route, :channel),
      "external_room_id" => route_value(route, :external_room_id),
      "reason" => inspect(metadata_value(failure, :reason))
    }
    |> compact_metadata()
  end

  defp route_metadata(nil), do: %{}

  defp route_metadata(route) do
    %{
      "bridge_id" => route_value(route, :bridge_id),
      "channel" => route_value(route, :channel),
      "delivery_external_room_id" => route_value(route, :external_room_id)
    }
    |> compact_metadata()
  end

  defp route_value(route, key), do: route |> metadata_value(key) |> normalize_delivery_value()

  defp normalize_delivery_value(nil), do: nil
  defp normalize_delivery_value(value) when is_binary(value), do: value
  defp normalize_delivery_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_delivery_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_delivery_value(value), do: inspect(value)

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = time), do: Calendar.strftime(time, "%H:%M:%S")

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp present(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      present -> present
    end
  end

  defp present(_value), do: nil
  defp present?(value), do: not is_nil(present(value))
end
