import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :whispr_messaging, WhisprMessaging.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "whispr_messaging_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Configure the endpoint
config :whispr_messaging, WhisprMessagingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "VGVzdGluZ1NlY3JldEtleUJhc2VGb3JXaGlzcHJNZXNzYWdpbmdTZXJ2aWNlVGVzdEVudmlyb25tZW50",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Configure Redis for testing
config :whispr_messaging, :redis,
  host: "localhost",
  port: 6379,
  # Different database for tests
  database: 1

# Configure PubSub for testing
config :whispr_messaging, WhisprMessaging.PubSub,
  name: WhisprMessaging.PubSub,
  adapter: Phoenix.PubSub.PG2

# Configure gRPC for testing
config :whispr_messaging, :grpc_port, 50053

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks in development
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
