defmodule Mix.Tasks.Compile.AssemblyHologramPrune do
  @moduledoc false

  use Mix.Task.Compiler

  @recursive true

  @server_only_apps [
    :jido_messaging,
    :jido_ai,
    :jido,
    :jido_signal,
    :jido_action,
    :jido_chat,
    :zoi,
    :yaml_elixir,
    :dotenvy,
    :yamerl,
    :fsmx,
    :req_llm,
    :req,
    :finch,
    :mint,
    :nimble_pool,
    :ex_aws_auth,
    :jsv,
    :llm_db,
    :server_sent_events,
    :uniq,
    :websockex,
    :deep_merge,
    :toml,
    :abnf_parsec,
    :idna,
    :texture,
    :nimble_parsec,
    :abacus,
    :lua,
    :multigraph,
    :private,
    :luerl,
    :fuse,
    :memento,
    :msgpax,
    :crontab,
    :ok,
    :poolboy,
    :time_zone_info,
    :splode
  ]

  @impl Mix.Task.Compiler
  def run(_args) do
    if System.get_env("HOLOGRAM_START") == "1" do
      Enum.each(@server_only_apps, &Application.unload/1)
    end

    {:noop, []}
  end
end
