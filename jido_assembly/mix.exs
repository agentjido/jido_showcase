defmodule Jido.Assembly.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_assembly,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      # No patched cowlib Hex release is available yet.
      hex: [ignore_advisories: ["CVE-2026-43969", "CVE-2026-43966"]],
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:assembly_hologram_prune, :hologram],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Jido.Assembly.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Documented Hologram option: app/ contains compiled page/component modules,
  # while lib/ contains the Phoenix backend and Assembly context modules.
  defp elixirc_paths(:test), do: ["app", "lib", "test/support"]
  defp elixirc_paths(_), do: ["app", "lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:hologram, "~> 0.10.1"},
      {:jido_messaging, "~> 1.1"},
      {:jido_chat_discord, "~> 1.0"},
      {:jido_chat_telegram, "~> 1.1"},
      {:jido_ai, "~> 2.2"},
      {:dotenvy, "~> 1.1"},
      {:lazy_html, "~> 0.1.12", only: :test},
      {:req, "~> 0.6.3", override: true},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "assets.setup",
        "assets.build"
      ],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind jido_assembly", "esbuild jido_assembly"],
      "assets.deploy": [
        "tailwind jido_assembly --minify",
        "esbuild jido_assembly --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --check-unused", "format", "test"]
    ]
  end
end
