defmodule WhisprMessaging.RedisConfigTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.RedisConfig

  setup do
    prev = Application.get_env(:whispr_messaging, :redis)
    on_exit(fn -> Application.put_env(:whispr_messaging, :redis, prev) end)
    :ok
  end

  describe "parse_sentinels/1" do
    test "parses a list of host:port pairs" do
      assert RedisConfig.parse_sentinels("s1:26_379,s2:26_380") == [
               [host: "s1", port: 26_379],
               [host: "s2", port: 26_380]
             ]
    end

    test "defaults to port 26_379 when missing" do
      assert RedisConfig.parse_sentinels("only-host") == [[host: "only-host", port: 26_379]]
    end

    test "trims whitespace around entries" do
      assert RedisConfig.parse_sentinels("  a:1 ,  b:2  ") == [
               [host: "a", port: 1],
               [host: "b", port: 2]
             ]
    end
  end

  describe "build/0 in direct mode" do
    test "honours host/port/database from app config" do
      Application.put_env(:whispr_messaging, :redis,
        mode: "direct",
        host: "h",
        port: 7000,
        database: 7
      )

      opts = RedisConfig.build()
      assert Keyword.get(opts, :host) == "h"
      assert Keyword.get(opts, :port) == 7000
      assert Keyword.get(opts, :database) == 7
    end

    test "applies sensible defaults when the config is empty" do
      Application.put_env(:whispr_messaging, :redis, [])
      opts = RedisConfig.build()
      assert Keyword.get(opts, :host) == "localhost"
      assert Keyword.get(opts, :port) == 6379
      assert Keyword.get(opts, :database) == 0
      refute Keyword.has_key?(opts, :password)
      refute Keyword.has_key?(opts, :ssl)
    end

    test "includes password and ssl when set" do
      Application.put_env(:whispr_messaging, :redis,
        mode: "direct",
        password: "secret",
        ssl: true
      )

      opts = RedisConfig.build()
      assert Keyword.get(opts, :password) == "secret"
      assert Keyword.get(opts, :ssl) == true
    end

    test "drops empty-string password" do
      Application.put_env(:whispr_messaging, :redis, mode: "direct", password: "")
      opts = RedisConfig.build()
      refute Keyword.has_key?(opts, :password)
    end
  end

  describe "build/0 in sentinel mode" do
    test "builds sentinel-shaped options" do
      Application.put_env(:whispr_messaging, :redis,
        mode: "sentinel",
        sentinels: "s1:26_379,s2:26_380",
        master_name: "mymaster",
        database: 1,
        password: "p",
        sentinel_password: "sp"
      )

      opts = RedisConfig.build()
      sentinel_cfg = Keyword.fetch!(opts, :sentinel)
      assert Keyword.fetch!(sentinel_cfg, :group) == "mymaster"

      assert Keyword.fetch!(sentinel_cfg, :sentinels) == [
               [host: "s1", port: 26_379],
               [host: "s2", port: 26_380]
             ]

      assert Keyword.fetch!(sentinel_cfg, :password) == "sp"
      assert Keyword.fetch!(opts, :password) == "p"
      assert Keyword.fetch!(opts, :database) == 1
    end

    test "raises when sentinels list is missing" do
      Application.put_env(:whispr_messaging, :redis, mode: "sentinel", master_name: "m")

      assert_raise RuntimeError, ~r/REDIS_SENTINELS/, fn ->
        RedisConfig.build()
      end
    end

    test "raises when master_name is missing" do
      Application.put_env(:whispr_messaging, :redis, mode: "sentinel", sentinels: "s1:26_379")

      assert_raise RuntimeError, ~r/REDIS_MASTER_NAME/, fn ->
        RedisConfig.build()
      end
    end
  end
end
