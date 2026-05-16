defmodule WhisprMessagingWeb.Plugs.RateLimiterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias WhisprMessagingWeb.Plugs.RateLimiter

  @moduletag :integration

  setup do
    # FLUSHDB on the test Redis db so each test starts with a clean state.
    {:ok, _} = Redix.command(:redix, ["FLUSHDB"])
    :ok
  end

  defp build(path, ip \\ "127.0.0.1") do
    conn(:get, path)
    |> Map.put(:remote_ip, parse_ip(ip))
  end

  defp parse_ip(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  describe "init/1" do
    test "applies defaults" do
      opts = RateLimiter.init([])
      assert opts.limit == 100
      assert opts.window_seconds == 60
      assert is_function(opts.key_func, 1)
    end

    test "honours overrides" do
      key_func = fn _ -> "fixed-key" end
      opts = RateLimiter.init(limit: 5, window_seconds: 10, key_func: key_func)
      assert opts.limit == 5
      assert opts.window_seconds == 10
      assert opts.key_func == key_func
    end
  end

  describe "call/2" do
    test "passes the request when under the limit and sets rate-limit headers" do
      opts = RateLimiter.init(limit: 5, window_seconds: 60)
      conn = build("/api/health")
      result = RateLimiter.call(conn, opts)

      refute result.halted
      assert get_resp_header(result, "x-ratelimit-limit") == ["5"]
      [remaining] = get_resp_header(result, "x-ratelimit-remaining")
      assert String.to_integer(remaining) >= 0
      assert get_resp_header(result, "x-ratelimit-reset") != []
    end

    test "returns 429 once the limit is reached for the same key" do
      opts = RateLimiter.init(limit: 2, window_seconds: 60)

      r1 = RateLimiter.call(build("/api/login"), opts)
      r2 = RateLimiter.call(build("/api/login"), opts)
      r3 = RateLimiter.call(build("/api/login"), opts)

      refute r1.halted
      refute r2.halted
      assert r3.halted
      assert r3.status == 429
      assert get_resp_header(r3, "x-ratelimit-remaining") == ["0"]
      assert [retry_after] = get_resp_header(r3, "retry-after")
      assert String.to_integer(retry_after) >= 1

      assert {:ok, body} = Jason.decode(r3.resp_body)
      assert body["error"] == "Too Many Requests"
      assert is_integer(body["retry_after"])
    end

    test "counts each IP / path combination independently" do
      opts = RateLimiter.init(limit: 1, window_seconds: 60)

      r1 = RateLimiter.call(build("/api/login", "10.0.0.1"), opts)
      r2 = RateLimiter.call(build("/api/login", "10.0.0.2"), opts)
      r3 = RateLimiter.call(build("/api/other", "10.0.0.1"), opts)

      refute r1.halted
      refute r2.halted
      refute r3.halted
    end

    test "uses x-forwarded-for if present" do
      opts = RateLimiter.init(limit: 1, window_seconds: 60)

      conn_forwarded =
        build("/api/path")
        |> put_req_header("x-forwarded-for", "192.168.1.42")

      r1 = RateLimiter.call(conn_forwarded, opts)
      refute r1.halted

      # A second request with the same forwarded IP should be rate-limited
      conn_same =
        build("/api/path")
        |> put_req_header("x-forwarded-for", "192.168.1.42")

      r2 = RateLimiter.call(conn_same, opts)
      assert r2.halted
      assert r2.status == 429
    end

    test "supports a custom key_func" do
      key_func = fn _conn -> "fixed-test-key" end
      opts = RateLimiter.init(limit: 1, window_seconds: 60, key_func: key_func)

      r1 = RateLimiter.call(build("/whatever"), opts)
      r2 = RateLimiter.call(build("/different-path"), opts)

      refute r1.halted
      # Same fixed key → second request is over the limit
      assert r2.halted
      assert r2.status == 429
    end
  end
end
