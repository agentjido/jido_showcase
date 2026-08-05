# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jido_assembly,
  namespace: Jido.Assembly,
  generators: [timestamp_type: :utc_datetime],
  sqlite_path: "data/jido_assembly.sqlite3"

config :jido_ai,
  model_aliases: %{
    assembly_haiku: "anthropic:claude-haiku-4-5"
  },
  llm_defaults: %{
    text: %{model: :assembly_haiku, temperature: 0.45, max_tokens: 220, timeout: 30_000}
  }

# Configure the endpoint
config :jido_assembly, Jido.AssemblyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Jido.AssemblyWeb.ErrorHTML, json: Jido.AssemblyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Jido.Assembly.PubSub,
  live_view: [signing_salt: "iY5qQOEC"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  jido_assembly: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  jido_assembly: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
