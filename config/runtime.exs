import Config

# Runtime configuration for production
# This file is executed for all environments (dev, test, prod)
# but we only configure runtime values for production here

if config_env() == :prod do
  # Database configuration
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :whispr_messaging, WhisprMessaging.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # Phoenix Endpoint configuration
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("HTTP_PORT") || "4000")

  config :whispr_messaging, WhisprMessagingWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  # Redis configuration
  redis_password = System.get_env("REDIS_PASSWORD")
  
  redis_config = [
    host: System.get_env("REDIS_HOST") || "localhost",
    port: String.to_integer(System.get_env("REDIS_PORT") || "6379"),
    database: String.to_integer(System.get_env("REDIS_DB") || "0"),
    timeout: 15_000,
    ssl: System.get_env("REDIS_SSL") == "true"
  ]
  
  redis_config = if redis_password && redis_password != "" do
    Keyword.put(redis_config, :password, redis_password)
  else
    redis_config
  end
  
  config :whispr_messaging, :redis, redis_config

  # gRPC configuration
  config :whispr_messaging, :grpc,
    port: String.to_integer(System.get_env("GRPC_PORT") || "50051")

  # Scheduling service gRPC URL
  config :whispr_messaging, :scheduling_service,
    grpc_url: System.get_env("SCHEDULING_SERVICE_GRPC_URL") || "localhost:50050"

  # Encryption configuration
  config :whispr_messaging, :encryption,
    key: System.get_env("ENCRYPTION_KEY") || raise("ENCRYPTION_KEY is required")

  # JWT configuration
  config :whispr_messaging, :jwt,
    secret: System.get_env("JWT_SECRET") || raise("JWT_SECRET is required")

  # Logging level
  log_level = System.get_env("LOG_LEVEL") || "info"
  config :logger, level: String.to_atom(log_level)
end
