# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :whispr_messaging,
  ecto_repos: [WhisprMessaging.Repo],
  generators: [binary_id: true]

# Configures the endpoint
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: WhisprMessagingWeb.ErrorHTML, json: WhisprMessagingWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WhisprMessaging.PubSub,
  live_view: [signing_salt: "messaging_secret"],
  server: true

# Configure Phoenix Channels
config :whispr_messaging, WhisprMessagingWeb.UserSocket,
  timeout: 45_000,
  transport_log: false,
  check_origin: false

# Redis configuration
config :whispr_messaging, :redis,
  host: System.get_env("REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
  database: String.to_integer(System.get_env("REDIS_DB", "0")),
  password: System.get_env("REDIS_PASSWORD")

# gRPC configuration
config :whispr_messaging,
  grpc_port: String.to_integer(System.get_env("GRPC_PORT", "50052"))

# Conversation GenServer configuration
config :whispr_messaging, :conversations,
  max_idle_time: String.to_integer(System.get_env("CONVERSATION_MAX_IDLE_TIME", "3600000")),
  cleanup_interval: String.to_integer(System.get_env("CONVERSATION_CLEANUP_INTERVAL", "300000")),
  max_message_cache: String.to_integer(System.get_env("MAX_MESSAGE_CACHE", "100"))

# Message configuration
config :whispr_messaging, :messages,
  max_content_size: String.to_integer(System.get_env("MAX_MESSAGE_SIZE", "65536")),
  retention_days: String.to_integer(System.get_env("MESSAGE_RETENTION_DAYS", "365")),
  cleanup_batch_size: String.to_integer(System.get_env("CLEANUP_BATCH_SIZE", "1000"))

# Inter-service communication
config :whispr_messaging, :services,
  auth_service: %{
    host: System.get_env("AUTH_SERVICE_HOST", "auth-service"),
    port: String.to_integer(System.get_env("AUTH_SERVICE_PORT", "50056"))
  },
  user_service: %{
    host: System.get_env("USER_SERVICE_HOST", "user-service"),
    port: String.to_integer(System.get_env("USER_SERVICE_PORT", "50055"))
  },
  media_service: %{
    host: System.get_env("MEDIA_SERVICE_HOST", "media-service"),
    port: String.to_integer(System.get_env("MEDIA_SERVICE_PORT", "50054"))
  },
  notification_service: %{
    host: System.get_env("NOTIFICATION_SERVICE_HOST", "notification-service"),
    port: String.to_integer(System.get_env("NOTIFICATION_SERVICE_PORT", "50053"))
  },
  moderation_service: %{
    host: System.get_env("MODERATION_SERVICE_HOST", "moderation-service"),
    port: String.to_integer(System.get_env("MODERATION_SERVICE_PORT", "50057"))
  }

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :conversation_id, :user_id]

# Phoenix LiveView configuration
config :phoenix, :json_library, Jason

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure telemetry - simplified for tests
config :whispr_messaging, WhisprMessagingWeb.Telemetry, metrics: []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
