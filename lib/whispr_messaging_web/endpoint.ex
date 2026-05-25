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

  # Shared WebSocket options — single source of truth for both mounts.
  # `check_origin` is resolved at runtime via {Mod, Fun, Args} so prod can
  # reuse the CORS allowlist (WHISPR-839) while dev/test stay permissive.
  # `connect_info` expose peer_data (IP client) et x_headers (User-Agent,
  # X-Forwarded-For) au UserSocket.connect/3 pour les logs de rejet (WHISPR-1240).
  @ws_opts [
    websocket: [
      timeout: 45_000,
      transport_log: false,
      compress: true,
      check_origin: {__MODULE__, :ws_check_origin, []}
    ],
    longpoll: false,
    connect_info: [:peer_data, :x_headers]
  ]

  socket "/socket", WhisprMessagingWeb.UserSocket, @ws_opts
  # Ingress-prefixed path so clients behind /messaging can reach the socket.
  socket "/messaging/socket", WhisprMessagingWeb.UserSocket, @ws_opts

  @doc """
  WebSocket origin check (WHISPR-839).

  Invoked by Phoenix as an MFA per-connection with the request `%URI{}`.

  - In `:prod`, only origins listed in `CORS_ALLOWED_ORIGINS` (comma-separated)
    are accepted. An unset/empty value or a wildcard raises — we refuse to
    boot a permissive WebSocket transport in production.
  - In `:dev`/`:test`, returns `true` (permissive) to keep local tooling
    and tests working without extra configuration.
  """
  @spec ws_check_origin(URI.t()) :: boolean()
  def ws_check_origin(%URI{} = uri) do
    case Application.get_env(:whispr_messaging, :env) do
      :prod ->
        prod_origin_allowed?(uri)

      _ ->
        true
    end
  end

  defp prod_origin_allowed?(%URI{} = uri) do
    case System.get_env("CORS_ALLOWED_ORIGINS") do
      nil ->
        raise "CORS_ALLOWED_ORIGINS must be set in production for WebSocket origin check (WHISPR-839)"

      "" ->
        raise "CORS_ALLOWED_ORIGINS cannot be empty in production for WebSocket origin check (WHISPR-839)"

      "*" ->
        raise "CORS_ALLOWED_ORIGINS=* is not allowed for WebSocket origin check in production (WHISPR-839)"

      value ->
        origins =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        origin_string = build_origin_string(uri)
        origin_string in origins
    end
  end

  defp build_origin_string(%URI{scheme: scheme, host: host, port: port})
       when is_binary(scheme) and is_binary(host) do
    base = "#{scheme}://#{host}"

    cond do
      is_nil(port) -> base
      scheme == "https" and port == 443 -> base
      scheme == "http" and port == 80 -> base
      true -> "#{base}:#{port}"
    end
  end

  defp build_origin_string(_), do: ""

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
  plug WhisprMessagingWeb.Plugs.LoggerMetadata
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug WhisprMessagingWeb.Plugs.Cors

  plug WhisprMessagingWeb.Plugs.ForwardedPrefix
  plug WhisprMessagingWeb.Router
end
