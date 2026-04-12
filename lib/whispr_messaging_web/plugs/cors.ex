defmodule WhisprMessagingWeb.Plugs.Cors do
  @moduledoc """
  CORS headers for cross-origin requests.

  The allowed origin is selected from the `CORS_ALLOWED_ORIGINS` env var
  (comma-separated list). If the request `origin` matches one of those
  entries, it is echoed back and `vary: origin` is set. If the list contains
  `*`, every origin is allowed. When no list is configured, defaults to `*`
  for development.
  """

  import Plug.Conn

  @default_headers "authorization, content-type, accept, x-user-id"
  @default_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts), do: put_cors_headers(conn)

  defp put_cors_headers(conn) do
    origin = conn |> get_req_header("origin") |> List.first()

    conn
    |> put_allow_origin(origin)
    |> put_resp_header("access-control-allow-methods", @default_methods)
    |> put_resp_header("access-control-allow-headers", @default_headers)
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp put_allow_origin(conn, origin) do
    allowed = allowed_origins()

    cond do
      allowed == ["*"] ->
        put_resp_header(conn, "access-control-allow-origin", "*")

      is_binary(origin) and origin in allowed ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("vary", "origin")

      true ->
        conn
    end
  end

  defp allowed_origins do
    case System.get_env("CORS_ALLOWED_ORIGINS") do
      nil ->
        ["*"]

      "" ->
        ["*"]

      value ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end
end
