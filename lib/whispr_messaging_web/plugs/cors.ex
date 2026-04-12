defmodule WhisprMessagingWeb.Plugs.Cors do
  @moduledoc "CORS headers for cross-origin requests."
  import Plug.Conn

  @allowed_origins_default "https://whispr-api.roadmvn.com,https://whispr-preprod.roadmvn.com,https://preprod-whispr-api.roadmvn.com,https://whispr.epitech.beer"

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts), do: put_cors_headers(conn)

  defp put_cors_headers(conn) do
    origin = get_req_header(conn, "origin") |> List.first()

    if origin && origin in allowed_origins() do
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, accept, x-user-id"
      )
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-max-age", "86400")
      |> put_resp_header("vary", "Origin")
    else
      conn
    end
  end

  defp allowed_origins do
    (System.get_env("CORS_ALLOWED_ORIGINS") || @allowed_origins_default)
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end
end
