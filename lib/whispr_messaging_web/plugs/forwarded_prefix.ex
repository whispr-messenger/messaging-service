defmodule WhisprMessagingWeb.Plugs.ForwardedPrefix do
  @moduledoc """
  Plug that reads the `x-forwarded-prefix` header (injected by Istio/Nginx when
  the external path prefix is stripped before forwarding to this service) and
  rewrites any `location` response header so that 3xx redirects point to the
  correct external URL including the original prefix.

  ## Example

  Istio rewrites `https://whispr.epitech.beer/messaging/api/swagger` to
  `/api/swagger` before forwarding here.  It also sets:

      x-forwarded-prefix: /messaging

  Without this plug, `PhoenixSwagger.Plug.SwaggerUI` would redirect to
  `/api/swagger/index.html`, which the browser resolves as
  `https://whispr.epitech.beer/api/swagger/index.html` — a 404.

  With this plug the `location` header becomes
  `/messaging/api/swagger/index.html`, which Istio correctly routes back to us.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "x-forwarded-prefix") do
      [prefix | _] when prefix != "" ->
        register_before_send(conn, fn conn ->
          rewrite_location(conn, String.trim_trailing(prefix, "/"))
        end)

      _ ->
        conn
    end
  end

  # Only touch 3xx responses that carry a relative `location` header.
  defp rewrite_location(conn, prefix) do
    case get_resp_header(conn, "location") do
      [location | _] when not is_nil(location) ->
        new_location = prepend_prefix(location, prefix)
        put_resp_header(conn, "location", new_location)

      _ ->
        conn
    end
  end

  # Leave absolute URLs (http:// / https://) and already-prefixed paths alone.
  defp prepend_prefix("http" <> _ = url, _prefix), do: url

  defp prepend_prefix(path, prefix) do
    if String.starts_with?(path, prefix) do
      path
    else
      prefix <> path
    end
  end
end
