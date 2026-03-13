import Config

# Kubernetes service discovery may inject full URIs (e.g. "tcp://10.x.x.x:50056") into
# *_PORT variables instead of plain port numbers. This helper handles both formats.
parse_port = fn value ->
  case URI.parse(value) do
    %URI{port: port} when is_integer(port) -> port
    _ -> String.to_integer(value)
  end
end

# Execute in all environments (dev, test, prod)

# Configure the database
db_name =
  System.get_env("DB_NAME") ||
    case config_env() do
      :prod -> "whispr_messaging_prod"
      :dev -> "whispr_messaging_dev"
      :test -> "whispr_messaging_test#{System.get_env("MIX_TEST_PARTITION")}"
    end

config :whispr_messaging, WhisprMessaging.Repo,
  username: System.get_env("DB_USERNAME", "postgres"),
  password: System.get_env("DB_PASSWORD", "password"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: db_name,
  port: String.to_integer(System.get_env("DB_PORT", "5432")),
  pool_size:
    String.to_integer(
      System.get_env("DB_POOL_SIZE", if(config_env() == :prod, do: "20", else: "10"))
    ),
  ssl: System.get_env("DB_SSL", "false") == "true",
  socket_options: if(System.get_env("DB_IPV6", "false") == "true", do: [:inet6], else: [])

# Endpoint Configuration
if config_env() == :prod do
  port =
    System.get_env("HTTP_PORT") ||
      System.get_env("PORT") ||
      raise "expected the HTTP_PORT (or PORT) environment variable to be set"

  config :whispr_messaging, WhisprMessagingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)],
    url: [host: System.get_env("PHX_HOST", "localhost"), port: 443, scheme: "https"],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
else
  if port = System.get_env("PORT") do
    config :whispr_messaging, WhisprMessagingWeb.Endpoint,
      http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
  end
end

# Services Configuration
# Uses full gRPC URIs (e.g. "grpc://auth-service:50051") to avoid conflicts
# with Kubernetes auto-injected *_PORT variables (e.g. AUTH_SERVICE_PORT=tcp://...)
config :whispr_messaging, :services,
  auth_service: System.get_env("AUTH_SERVICE_URL", "grpc://auth-service:50056"),
  user_service: System.get_env("USER_SERVICE_URL", "grpc://user-service:50055"),
  media_service: System.get_env("MEDIA_SERVICE_URL", "grpc://media-service:50054"),
  notification_service:
    System.get_env("NOTIFICATION_SERVICE_URL", "grpc://notification-service:50053"),
  moderation_service: System.get_env("MODERATION_SERVICE_URL", "grpc://moderation-service:50057"),
  scheduling_service:
    System.get_env("SCHEDULING_SERVICE_GRPC_URL", "grpc://scheduling-service:50052")

# Redis Configuration
redis_mode = System.get_env("REDIS_MODE", "direct")

redis_config =
  case redis_mode do
    "sentinel" ->
      [
        mode: "sentinel",
        sentinels: System.get_env("REDIS_SENTINELS"),
        master_name: System.get_env("REDIS_MASTER_NAME"),
        sentinel_password: System.get_env("REDIS_SENTINEL_PASSWORD"),
        database:
          String.to_integer(
            System.get_env("REDIS_DB", if(config_env() == :test, do: "1", else: "0"))
          ),
        username: System.get_env("REDIS_USERNAME"),
        password: System.get_env("REDIS_PASSWORD"),
        timeout: 15_000,
        ssl: System.get_env("REDIS_SSL", "false") == "true"
      ]

    _ ->
      [
        mode: "direct",
        host: System.get_env("REDIS_HOST", "localhost"),
        port: parse_port.(System.get_env("REDIS_PORT", "6379")),
        database:
          String.to_integer(
            System.get_env("REDIS_DB", if(config_env() == :test, do: "1", else: "0"))
          ),
        username: System.get_env("REDIS_USERNAME"),
        password: System.get_env("REDIS_PASSWORD"),
        timeout: 15_000,
        ssl: System.get_env("REDIS_SSL", "false") == "true"
      ]
  end

config :whispr_messaging, :redis, redis_config

# GenServer & Application specifics Configuration
config :whispr_messaging, :conversations,
  max_idle_time: String.to_integer(System.get_env("CONVERSATION_MAX_IDLE_TIME", "3600000")),
  cleanup_interval: String.to_integer(System.get_env("CONVERSATION_CLEANUP_INTERVAL", "300000")),
  max_message_cache: String.to_integer(System.get_env("MAX_MESSAGE_CACHE", "100"))

config :whispr_messaging, :messages,
  max_content_size: String.to_integer(System.get_env("MAX_MESSAGE_SIZE", "65536")),
  retention_days: String.to_integer(System.get_env("MESSAGE_RETENTION_DAYS", "365")),
  cleanup_batch_size: String.to_integer(System.get_env("CLEANUP_BATCH_SIZE", "1000"))

config :whispr_messaging,
  grpc_port: String.to_integer(System.get_env("GRPC_PORT", "40010"))
