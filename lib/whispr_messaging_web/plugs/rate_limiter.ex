defmodule WhisprMessagingWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using Redis for distributed rate limiting.

  Implements sliding window algorithm with Redis.
  """

  import Plug.Conn
  require Logger

  @default_limit 100
  @default_window_seconds 60

  def init(opts) do
    %{
      limit: Keyword.get(opts, :limit, @default_limit),
      window_seconds: Keyword.get(opts, :window_seconds, @default_window_seconds),
      key_func: Keyword.get(opts, :key_func, &default_key/1)
    }
  end

  def call(conn, opts) do
    key = opts.key_func.(conn)

    case check_rate_limit(key, opts.limit, opts.window_seconds) do
      {:ok, _count, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-limit", "#{opts.limit}")
        |> put_resp_header("x-ratelimit-remaining", "#{remaining}")
        |> put_resp_header("x-ratelimit-reset", "#{get_reset_time(opts.window_seconds)}")

      {:error, :rate_limited, retry_after} ->
        Logger.warning("Rate limit exceeded", key: key, domain: :rate_limiter)

        conn
        |> put_resp_header("x-ratelimit-limit", "#{opts.limit}")
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("retry-after", "#{retry_after}")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "Too Many Requests",
            message: "Rate limit exceeded. Please retry after #{retry_after} seconds.",
            retry_after: retry_after
          })
        )
        |> halt()
    end
  end

  # Private functions

  # WHISPR-1387 : la cle priorise user_id (set par le plug Authenticate).
  # Derriere Cloudflare ou un ingress k8s l'IP vue est celle du proxy partage,
  # donc une cle IP-only met tous les users du meme CDN dans le meme bucket.
  # Pour les routes non-authentifiees (login, OTP, /health) on garde un fallback
  # IP, qui reste imparfait mais c'est le seul identifiant disponible.
  defp default_key(conn) do
    path = conn.request_path

    case conn.assigns[:user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        "rate_limit:user:#{user_id}:#{path}"

      _ ->
        ip = get_client_ip(conn)
        "rate_limit:ip:#{ip}:#{path}"
    end
  end

  defp get_client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        ip

      [] ->
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          ip -> to_string(ip)
        end
    end
  end

  defp check_rate_limit(key, limit, window_seconds) do
    now = System.system_time(:second)
    window_start = now - window_seconds

    # Use Redis sorted set to track requests
    case Redix.pipeline(:redix, [
           ["ZREMRANGEBYSCORE", key, "-inf", window_start],
           ["ZCARD", key],
           ["ZADD", key, now, "#{now}-#{:rand.uniform(1_000_000)}"],
           ["EXPIRE", key, window_seconds]
         ]) do
      {:ok, [_removed, count, _added, _expire]} ->
        count = if is_binary(count), do: String.to_integer(count), else: count

        if count < limit do
          {:ok, count, limit - count}
        else
          oldest_request_time = get_oldest_request_time(key)
          retry_after = max(1, window_seconds - (now - oldest_request_time))
          {:error, :rate_limited, retry_after}
        end

      {:error, reason} ->
        Logger.error("Redis error in rate limiter",
          reason: inspect(reason),
          domain: :rate_limiter
        )

        # Fail open - allow request if Redis is down
        {:ok, 0, limit}
    end
  end

  defp get_oldest_request_time(key) do
    case Redix.command(:redix, ["ZRANGE", key, "0", "0", "WITHSCORES"]) do
      {:ok, [_value, score]} -> String.to_integer(score)
      _ -> System.system_time(:second)
    end
  end

  defp get_reset_time(window_seconds) do
    System.system_time(:second) + window_seconds
  end
end
