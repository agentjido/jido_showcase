import Config
import Dotenvy

if config_env() == :test do
  test_run_id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  test_db = Path.join(System.tmp_dir!(), "jido-assembly-#{test_run_id}.sqlite3")
  config :jido_assembly, :sqlite_path, test_db
else
  app_root = System.get_env("RELEASE_ROOT") || Path.expand("..", __DIR__)

  source!([
    System.get_env(),
    Path.join(app_root, ".env"),
    System.get_env()
  ])
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/jido_assembly start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :jido_assembly, Jido.AssemblyWeb.Endpoint, server: true
end

config :jido_assembly, Jido.AssemblyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

agent_mode =
  case System.get_env("JIDO_ASSEMBLY_AGENT_MODE") do
    "scripted" -> :scripted
    _other -> :live
  end

config :jido_assembly, :agent_mode, agent_mode

if config_env() != :test do
  case System.get_env("JIDO_ASSEMBLY_ROSTER") do
    nil ->
      config :jido_assembly, :require_pilot, config_env() == :prod

    roster ->
      database = System.get_env("JIDO_ASSEMBLY_PILOT_DB")

      if database in [nil, "", ":memory:"] or
           Path.expand(database) == Path.expand("data/jido_assembly_v3.sqlite3") do
        raise "Set JIDO_ASSEMBLY_PILOT_DB to a dedicated SQLite file."
      end

      config :jido_assembly, pilot_roster: roster, sqlite_path: Path.expand(database)

      config :jido_assembly, :agent_trigger_options,
        enabled: System.get_env("JIDO_ASSEMBLY_PILOT_AGENTS") == "1"
  end
end

if System.get_env("JIDO_ASSEMBLY_RELEASE_DELEGATION") == "1" and config_env() != :test do
  config :jido_assembly, :agent_trigger_options,
    release_delegation: true,
    release_publication_recommendation:
      System.get_env("JIDO_ASSEMBLY_RELEASE_PUBLICATION_RECOMMENDATION") == "1",
    release_peer_context: System.get_env("JIDO_ASSEMBLY_RELEASE_PEER_CONTEXT") != "0",
    release_rollout_required: System.get_env("JIDO_ASSEMBLY_RELEASE_ROLLOUT_REQUIRED") != "0"
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :jido_assembly, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :jido_assembly, Jido.AssemblyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :jido_assembly, Jido.AssemblyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :jido_assembly, Jido.AssemblyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
