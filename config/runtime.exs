import Config

if config_env() == :prod do
  port =
    System.get_env("HTTP_PORT") ||
      System.get_env("PORT") ||
      raise "expected the HTTP_PORT (or PORT) environment variable to be set"

  config :whispr_messaging, WhisprMessagingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")

  # ---------------------------------------------------------------------------
  # Redis – evaluated at runtime so environment variables are always read from
  # the actual process environment (not at compile time).
  # ---------------------------------------------------------------------------
  redis_mode = System.get_env("REDIS_MODE", "direct")

  redis_config =
    case redis_mode do
      "sentinel" ->
        [
          mode: "sentinel",
          sentinels: System.get_env("REDIS_SENTINELS"),
          master_name: System.get_env("REDIS_MASTER_NAME"),
          sentinel_password: System.get_env("REDIS_SENTINEL_PASSWORD"),
          database: String.to_integer(System.get_env("REDIS_DB", "0")),
          password: System.get_env("REDIS_PASSWORD"),
          timeout: 15_000
        ]

      _ ->
        [
          mode: "direct",
          host: System.get_env("REDIS_HOST", "localhost"),
          port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
          database: String.to_integer(System.get_env("REDIS_DB", "0")),
          password: System.get_env("REDIS_PASSWORD"),
          timeout: 15_000,
          ssl: System.get_env("REDIS_SSL", "false") == "true"
        ]
    end

  config :whispr_messaging, :redis, redis_config
end
