import Config

# Configure your database for production
config :whispr_messaging, WhisprMessaging.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "whispr_messaging_prod"),
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "20")),
  ssl: System.get_env("DB_SSL", "false") == "true",
  socket_options: if(System.get_env("DB_IPV6", "false") == "true", do: [:inet6], else: [])

# Production endpoint configuration
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: String.to_integer(System.get_env("PORT", "4000"))
  ],
  url: [host: System.get_env("PHX_HOST", "localhost"), port: 443, scheme: "https"],
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  check_origin: false,
  server: true

# Redis configuration is handled entirely in config/runtime.exs so that
# environment variables (including REDIS_MODE / REDIS_SENTINELS) are always
# resolved from the live process environment rather than at compile time.

# Production logging - JSON format for structured logging
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :conversation_id, :user_id],
  level: :info

config :logger,
  level: :info

# Production conversation settings
config :whispr_messaging, :conversations,
  max_idle_time: String.to_integer(System.get_env("CONVERSATION_MAX_IDLE_TIME", "3600000")),
  cleanup_interval: String.to_integer(System.get_env("CONVERSATION_CLEANUP_INTERVAL", "300000")),
  max_message_cache: String.to_integer(System.get_env("MAX_MESSAGE_CACHE", "100"))

# Disable dev routes in production
config :whispr_messaging, dev_routes: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration
# The config/runtime.exs is executed after compilation
# and before the system starts, so it is a good place to
# configure values based on environment variables.
