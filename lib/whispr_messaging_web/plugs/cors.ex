defmodule WhisprMessagingWeb.Plugs.Cors do
  @moduledoc """
  CORS headers for cross-origin requests.

  Fail-closed semantics (WHISPR-1007):

  - When `CORS_ALLOWED_ORIGINS` is unset or empty **no CORS headers are
    emitted**. The browser blocks the cross-origin request. This is the
    safe default in preprod / prod.
  - An explicit `CORS_ALLOWED_ORIGINS="*"` still allows every origin
    (local-dev opt-in), but `access-control-allow-credentials` is **not**
    emitted in that case — the CORS spec forbids wildcard + credentials
    and browsers reject the combo anyway.
  - When the request `Origin` header matches the comma-separated
    allowlist, it is echoed back with `vary: origin` so caches key on
    the origin rather than serving one client's response to another.
  """

  import Plug.Conn
  require Logger

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
    allowed = allowed_origins()
    decision = decide_origin_header(origin, allowed)

    conn
    |> put_allow_origin(decision)
    |> maybe_put_common_headers(decision)
  end

  # Only emit the shared headers when we also emit an
  # `access-control-allow-origin` — otherwise the response is a regular
  # same-origin payload and the extra headers serve no purpose.
  defp maybe_put_common_headers(conn, :none), do: conn

  defp maybe_put_common_headers(conn, {:wildcard, _}) do
    conn
    |> put_resp_header("access-control-allow-methods", @default_methods)
    |> put_resp_header("access-control-allow-headers", @default_headers)
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp maybe_put_common_headers(conn, {:match, _}) do
    conn
    |> put_resp_header("access-control-allow-methods", @default_methods)
    |> put_resp_header("access-control-allow-headers", @default_headers)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-max-age", "86400")
  end

  defp put_allow_origin(conn, :none), do: conn

  defp put_allow_origin(conn, {:wildcard, _}) do
    put_resp_header(conn, "access-control-allow-origin", "*")
  end

  defp put_allow_origin(conn, {:match, value}) do
    conn
    |> put_resp_header("access-control-allow-origin", value)
    |> put_resp_header("vary", "origin")
  end

  defp decide_origin_header(_origin, []), do: :none
  defp decide_origin_header(_origin, ["*"]), do: {:wildcard, "*"}

  defp decide_origin_header(origin, allowed) when is_binary(origin) do
    if origin in allowed, do: {:match, origin}, else: :none
  end

  defp decide_origin_header(_origin, _allowed), do: :none

  defp allowed_origins do
    case {prod?(), System.get_env("CORS_ALLOWED_ORIGINS")} do
      {true, nil} ->
        raise "CORS_ALLOWED_ORIGINS must be set in production (WHISPR-838)"

      {true, ""} ->
        raise "CORS_ALLOWED_ORIGINS cannot be empty in production (WHISPR-838)"

      {false, nil} ->
        warn_missing_config()
        []

      {false, ""} ->
        warn_missing_config()
        []

      {_, value} ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp prod? do
    Application.get_env(:whispr_messaging, :env) == :prod
  end

  defp warn_missing_config do
    # Only warn once per process to keep logs tidy when the API is hammered.
    case Process.get(:whispr_cors_warn_logged) do
      true ->
        :ok

      _ ->
        Logger.warning(
          "CORS_ALLOWED_ORIGINS is unset — CORS headers will not be emitted. " <>
            "Cross-origin browsers will be blocked. Set the env var explicitly " <>
            "(comma-separated) or use '*' if truly needed in dev."
        )

        Process.put(:whispr_cors_warn_logged, true)
        :ok
    end
  end
end
