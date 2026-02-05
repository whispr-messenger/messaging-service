import Config

if config_env() == :prod do
  port = System.get_env("PORT") || raise "expected the PORT environment variable to be set"

  config :whispr_messaging, WhisprMessagingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
