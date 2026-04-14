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

# Disable tzdata autoupdates to avoid writing to read-only container file system
config :tzdata, :autoupdate, :disabled

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
  host: "localhost",
  port: 6379,
  database: 0

# gRPC configuration
config :whispr_messaging,
  grpc_port: 50052

# Conversation GenServer configuration
config :whispr_messaging, :conversations,
  max_idle_time: 3_600_000,
  cleanup_interval: 300_000,
  max_message_cache: 100

# Message configuration
config :whispr_messaging, :messages,
  max_content_size: 65536,
  retention_days: 365,
  cleanup_batch_size: 1000

# Inter-service communication
config :whispr_messaging, :services,
  auth_service: %{
    host: "auth-service",
    port: 50056
  },
  user_service: %{
    host: "user-service",
    port: 50055
  },
  media_service: %{
    host: "media-service",
    port: 50054
  },
  notification_service: %{
    host: "notification-service",
    port: 50053
  },
  moderation_service: %{
    host: "moderation-service",
    port: 50057
  }

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :conversation_id, :user_id, :query, :params]

# PhoenixSwagger configuration
config :whispr_messaging, :phoenix_swagger,
  json_library: Jason,
  swagger_files: %{
    "priv/static/swagger.json" => [
      router: WhisprMessagingWeb.Router,
      endpoint: WhisprMessagingWeb.Endpoint
    ]
  }

# Configure telemetry - simplified for tests
config :whispr_messaging, WhisprMessagingWeb.Telemetry, metrics: []

# Moderation auto-escalation thresholds
config :whispr_messaging, :moderation,
  mute_threshold: String.to_integer(System.get_env("MOD_MUTE_THRESHOLD") || "3"),
  mute_days: String.to_integer(System.get_env("MOD_MUTE_DAYS") || "7"),
  mute_duration_hours: String.to_integer(System.get_env("MOD_MUTE_DURATION_HOURS") || "24"),
  ban_threshold: String.to_integer(System.get_env("MOD_BAN_THRESHOLD") || "5"),
  ban_days: String.to_integer(System.get_env("MOD_BAN_DAYS") || "14"),
  review_threshold: String.to_integer(System.get_env("MOD_REVIEW_THRESHOLD") || "10"),
  review_days: String.to_integer(System.get_env("MOD_REVIEW_DAYS") || "30")

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
