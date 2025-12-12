defmodule WhisprMessagingWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for the WhisprMessaging application.

  Handles HTTP requests, WebSocket connections, and real-time messaging.
  """

  use Phoenix.Endpoint, otp_app: :whispr_messaging

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_whispr_messaging_key",
    signing_salt: "FcZt6Yoj",
    same_site: "Lax"
  ]

  # WebSocket configuration
  socket "/socket", WhisprMessagingWeb.UserSocket,
    websocket: [
      timeout: 45_000,
      transport_log: false,
      compress: true,
      # Configure appropriately for production
      check_origin: false
    ],
    longpoll: false

  # Serve static files from the "priv/static" directory
  plug Plug.Static,
    at: "/",
    from: :whispr_messaging,
    gzip: false,
    only: WhisprMessagingWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    # plug Phoenix.Ecto.CheckRepoStatus, otp_app: :whispr_messaging
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug WhisprMessagingWeb.Router

  @doc """
  Callback invoked for dynamically configuring the endpoint.

  It receives the endpoint configuration and checks if
  configuration should be loaded from the system environment.
  """
  def init(_key, config) do
    if config[:load_from_system_env] do
      port = System.get_env("PORT") || raise "expected the PORT environment variable to be set"
      {:ok, Keyword.put(config, :http, [:inet6, port: port])}
    else
      {:ok, config}
    end
  end
end
