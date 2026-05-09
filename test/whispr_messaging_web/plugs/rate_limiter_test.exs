defmodule WhisprMessagingWeb.Plugs.RateLimiterTest do
  @moduledoc """
  Tests for the Redis-backed rate limiter plug. Each test uses a unique
  request path so the underlying sorted set is isolated from other runs.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias WhisprMessagingWeb.Plugs.RateLimiter

  setup do
    suffix = System.unique_integer([:positive])
    path = "/test-rate-limiter-#{suffix}"

    # Build a base conn with a deterministic remote IP for the default key.
    base = build_conn(:get, path) |> Map.put(:remote_ip, {127, 0, 0, 1})

    on_exit(fn ->
      Redix.command(:redix, ["DEL", "rate_limit:ip:127.0.0.1:#{path}"])
    end)

    %{conn: base, path: path}
  end

  describe "init/1" do
    test "applies default options" do
      opts = RateLimiter.init([])
      assert opts.limit == 100
      assert opts.window_seconds == 60
      assert is_function(opts.key_func, 1)
    end

    test "respects user-provided options" do
      opts = RateLimiter.init(limit: 5, window_seconds: 1)
      assert opts.limit == 5
      assert opts.window_seconds == 1
    end
  end

  describe "call/2" do
    test "lets a request through under the limit and sets remaining headers", %{conn: conn} do
      opts = RateLimiter.init(limit: 5, window_seconds: 60)
      result = RateLimiter.call(conn, opts)

      refute result.halted
      assert ["5"] = get_resp_header(result, "x-ratelimit-limit")
      assert [_remaining] = get_resp_header(result, "x-ratelimit-remaining")
      assert [_reset] = get_resp_header(result, "x-ratelimit-reset")
    end

    test "blocks the request once the limit is exceeded", %{conn: conn} do
      opts = RateLimiter.init(limit: 2, window_seconds: 60)

      r1 = RateLimiter.call(conn, opts)
      r2 = RateLimiter.call(conn, opts)
      r3 = RateLimiter.call(conn, opts)

      refute r1.halted
      refute r2.halted
      assert r3.halted
      assert r3.status == 429

      assert ["0"] = get_resp_header(r3, "x-ratelimit-remaining")
      assert [retry_after] = get_resp_header(r3, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end

    test "uses x-forwarded-for IP when present", %{path: path} do
      conn =
        build_conn(:get, path)
        |> Map.put(:remote_ip, {1, 2, 3, 4})
        |> put_req_header("x-forwarded-for", "10.0.0.1")

      opts = RateLimiter.init(limit: 10, window_seconds: 60)
      result = RateLimiter.call(conn, opts)
      refute result.halted

      # Check the key built with the forwarded IP exists
      {:ok, count} = Redix.command(:redix, ["ZCARD", "rate_limit:ip:10.0.0.1:#{path}"])
      assert count >= 1
      Redix.command(:redix, ["DEL", "rate_limit:ip:10.0.0.1:#{path}"])
    end

    test "uses user_id when assigns[:user_id] is set (anti-CDN-bucket-collision)", %{path: path} do
      user_id = "user-#{System.unique_integer([:positive])}"

      conn =
        build_conn(:get, path)
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> assign(:user_id, user_id)

      opts = RateLimiter.init(limit: 10, window_seconds: 60)
      result = RateLimiter.call(conn, opts)
      refute result.halted

      # le bucket doit etre indexe sur user_id, pas sur l'IP
      {:ok, user_count} = Redix.command(:redix, ["ZCARD", "rate_limit:user:#{user_id}:#{path}"])
      assert user_count >= 1
      {:ok, ip_count} = Redix.command(:redix, ["ZCARD", "rate_limit:ip:127.0.0.1:#{path}"])
      assert ip_count == 0

      Redix.command(:redix, ["DEL", "rate_limit:user:#{user_id}:#{path}"])
    end

    test "fallback IP quand assigns[:user_id] absent (route non-authentifiee)", %{path: path} do
      conn =
        build_conn(:get, path)
        |> Map.put(:remote_ip, {192, 168, 1, 42})

      opts = RateLimiter.init(limit: 10, window_seconds: 60)
      result = RateLimiter.call(conn, opts)
      refute result.halted

      {:ok, ip_count} = Redix.command(:redix, ["ZCARD", "rate_limit:ip:192.168.1.42:#{path}"])
      assert ip_count >= 1

      Redix.command(:redix, ["DEL", "rate_limit:ip:192.168.1.42:#{path}"])
    end

    test "deux users derriere le meme IP ne partagent PAS le bucket", %{path: path} do
      user_a = "user-a-#{System.unique_integer([:positive])}"
      user_b = "user-b-#{System.unique_integer([:positive])}"

      build_authed = fn user_id ->
        build_conn(:get, path)
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> assign(:user_id, user_id)
      end

      opts = RateLimiter.init(limit: 1, window_seconds: 60)

      # user_a brule sa quota
      r1 = RateLimiter.call(build_authed.(user_a), opts)
      r2 = RateLimiter.call(build_authed.(user_a), opts)
      refute r1.halted
      assert r2.halted

      # user_b doit pouvoir passer malgre la meme IP
      r3 = RateLimiter.call(build_authed.(user_b), opts)
      refute r3.halted

      Redix.command(:redix, ["DEL", "rate_limit:user:#{user_a}:#{path}"])
      Redix.command(:redix, ["DEL", "rate_limit:user:#{user_b}:#{path}"])
    end

    test "supports a custom key function", %{path: path} do
      key_func = fn _conn -> "custom-rate-key-#{path}" end
      opts = RateLimiter.init(limit: 1, window_seconds: 60, key_func: key_func)

      conn = build_conn(:get, path)
      r1 = RateLimiter.call(conn, opts)
      r2 = RateLimiter.call(conn, opts)

      refute r1.halted
      assert r2.halted
      assert r2.status == 429

      Redix.command(:redix, ["DEL", "custom-rate-key-#{path}"])
    end
  end
end
