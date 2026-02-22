import Config

# Configure your database for production
config :whispr_messaging, WhisprMessaging.Repo,
  # These are placeholders that will be evaluated at runtime
  # Database configuration is handled entirely in config/runtime.exs
  pool_size: 20

# Production endpoint configuration
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  # Endpoint configuration is handled in config/runtime.exs
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
# Handled dynamically in config/runtime.exs
# config :whispr_messaging, :conversations

# Disable dev routes in production
config :whispr_messaging, dev_routes: false

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration
# The config/runtime.exs is executed after compilation
# and before the system starts, so it is a good place to
# configure values based on environment variables.
