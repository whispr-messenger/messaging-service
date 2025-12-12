import Config

# Configure your database
config :whispr_messaging, WhisprMessaging.Repo,
  username: System.get_env("DB_USERNAME", "root"),
  password: System.get_env("DB_PASSWORD", "root"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "whispr_messaging_dev"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  log: :debug

# For development, we disable any cache and enable
# debugging and code reloading.
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  # Binding to 0.0.0.0 to allow access from Docker host and other machines.
  # Use {127, 0, 0, 1} for local development only.
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "development_secret_key_base_please_change_in_production",
  watchers: []

# Watch static and templates for browser reloading.
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/whispr_messaging_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Development Redis configuration
config :whispr_messaging, :redis,
  host: System.get_env("REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
  database: String.to_integer(System.get_env("REDIS_DB", "0")),
  password: System.get_env("REDIS_PASSWORD"),
  timeout: 5000

# Enable dev routes for dashboard and mailbox
config :whispr_messaging, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console,
  format: "[$level] $message\n",
  level: :debug

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Configure telemetry for development
config :telemetry_poller, :default, period: 5_000

# Development-specific conversation settings
config :whispr_messaging, :conversations,
  # 30 minutes
  max_idle_time: 1_800_000,
  # 5 minutes
  cleanup_interval: 300_000,
  max_message_cache: 50

# Development logging
config :logger,
  backends: [:console],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]
