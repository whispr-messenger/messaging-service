defmodule WhisprMessaging.RedisConfigTest do
  @moduledoc """
  Tests for the Redis connection options builder. Saves and restores
  the application env so tests are deterministic.
  """

  use ExUnit.Case, async: false

  alias WhisprMessaging.RedisConfig

  setup do
    original = Application.get_env(:whispr_messaging, :redis, [])
    on_exit(fn -> Application.put_env(:whispr_messaging, :redis, original) end)
    :ok
  end

  defp set_redis_env(cfg), do: Application.put_env(:whispr_messaging, :redis, cfg)

  describe "build/0 in direct mode" do
    test "returns host/port/database with safe defaults" do
      set_redis_env(mode: "direct", host: "redis-host", port: 6380, database: 2)
      opts = RedisConfig.build()

      assert opts[:host] == "redis-host"
      assert opts[:port] == 6380
      assert opts[:database] == 2
    end

    test "merges optional credentials when provided" do
      set_redis_env(
        mode: "direct",
        host: "h",
        port: 1234,
        database: 0,
        password: "secret",
        username: "alice",
        timeout: 5_000
      )

      opts = RedisConfig.build()
      assert opts[:password] == "secret"
      assert opts[:username] == "alice"
      assert opts[:timeout] == 5_000
    end

    test "enables SSL when configured" do
      set_redis_env(mode: "direct", host: "h", port: 1, database: 0, ssl: true)
      assert Keyword.fetch!(RedisConfig.build(), :ssl) == true
    end

    test "drops nil/empty optional credentials" do
      set_redis_env(mode: "direct", host: "h", port: 1, database: 0, password: "", username: nil)
      opts = RedisConfig.build()
      refute Keyword.has_key?(opts, :password)
      refute Keyword.has_key?(opts, :username)
    end

    test "uses defaults when no host/port/database keys are present" do
      set_redis_env([])
      opts = RedisConfig.build()
      assert opts[:host] == "localhost"
      assert opts[:port] == 6379
      assert opts[:database] == 0
    end
  end

  describe "build/0 in sentinel mode" do
    test "raises if REDIS_SENTINELS is missing" do
      set_redis_env(mode: "sentinel", master_name: "mymaster")

      assert_raise RuntimeError, ~r/REDIS_SENTINELS is required/, fn ->
        RedisConfig.build()
      end
    end

    test "raises if REDIS_MASTER_NAME is missing" do
      set_redis_env(mode: "sentinel", sentinels: "s1:26379")

      assert_raise RuntimeError, ~r/REDIS_MASTER_NAME is required/, fn ->
        RedisConfig.build()
      end
    end

    test "builds sentinel options when both keys are present" do
      set_redis_env(
        mode: "sentinel",
        sentinels: "s1:26379,s2:26380",
        master_name: "mymaster",
        sentinel_password: "sentinelpw",
        password: "redispw",
        database: 3
      )

      opts = RedisConfig.build()
      sentinel = Keyword.fetch!(opts, :sentinel)

      assert sentinel[:group] == "mymaster"
      assert is_list(sentinel[:sentinels])
      assert sentinel[:password] == "sentinelpw"
      assert opts[:database] == 3
      assert opts[:password] == "redispw"
    end
  end

  describe "parse_sentinels/1" do
    test "parses host:port pairs" do
      assert [
               [host: "s1", port: 26_379],
               [host: "s2", port: 30_000]
             ] = RedisConfig.parse_sentinels("s1:26379, s2:30000")
    end

    test "defaults port to 26379 when missing" do
      assert [[host: "only-host", port: 26_379]] =
               RedisConfig.parse_sentinels("only-host")
    end
  end
end
