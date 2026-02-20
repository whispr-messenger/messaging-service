defmodule WhisprMessaging.RedisConfig do
  @moduledoc """
  Redis connection configuration builder.

  Supports two modes controlled by the `mode:` config key (set via `REDIS_MODE`
  environment variable):

    * `"direct"` (default) – single-node connection using `REDIS_HOST` / `REDIS_PORT`.
    * `"sentinel"` – Redis Sentinel HA mode using `REDIS_SENTINELS` /
      `REDIS_MASTER_NAME`.

  ## Required variables in sentinel mode

    * `REDIS_SENTINELS` – comma-separated list of sentinel addresses, e.g.
      `"sentinel1:26379,sentinel2:26379,sentinel3:26379"`
    * `REDIS_MASTER_NAME` – name of the Redis master group (e.g. `"mymaster"`)

  ## Optional variables (both modes)

    * `REDIS_PASSWORD` – Redis AUTH password
    * `REDIS_SENTINEL_PASSWORD` – AUTH password for sentinel nodes (sentinel mode only)
    * `REDIS_DB` – database index (default: `0`)
    * `REDIS_SSL` – set to `"true"` to enable TLS (direct mode only)
  """

  require Logger

  @doc """
  Builds the keyword list of Redix start options from the application config.

  Call this instead of reading `:redis` application env directly so the
  sentinel/direct branching is handled in a single place.
  """
  @spec build() :: keyword()
  def build do
    config = Application.get_env(:whispr_messaging, :redis, [])
    mode = Keyword.get(config, :mode, "direct")

    opts =
      case mode do
        "sentinel" -> sentinel_opts(config)
        _ -> direct_opts(config)
      end

    log_mode(mode, opts)
    opts
  end

  # ---------------------------------------------------------------------------
  # Direct mode
  # ---------------------------------------------------------------------------

  defp direct_opts(config) do
    base = [
      host: Keyword.get(config, :host, "localhost"),
      port: Keyword.get(config, :port, 6379),
      database: Keyword.get(config, :database, 0)
    ]

    base
    |> maybe_put(:username, Keyword.get(config, :username))
    |> maybe_put(:password, Keyword.get(config, :password))
    |> maybe_put(:timeout, Keyword.get(config, :timeout))
    |> then(fn opts ->
      if Keyword.get(config, :ssl, false), do: Keyword.put(opts, :ssl, true), else: opts
    end)
  end

  # ---------------------------------------------------------------------------
  # Sentinel mode
  # ---------------------------------------------------------------------------

  defp sentinel_opts(config) do
    sentinels_str =
      Keyword.get(config, :sentinels) ||
        raise "REDIS_SENTINELS is required when REDIS_MODE=sentinel"

    master_name =
      Keyword.get(config, :master_name) ||
        raise "REDIS_MASTER_NAME is required when REDIS_MODE=sentinel"

    sentinel_cfg =
      [
        sentinels: parse_sentinels(sentinels_str),
        group: master_name
      ]
      |> maybe_put(:password, Keyword.get(config, :sentinel_password))

    [
      sentinel: sentinel_cfg,
      database: Keyword.get(config, :database, 0)
    ]
    |> maybe_put(:username, Keyword.get(config, :username))
    |> maybe_put(:password, Keyword.get(config, :password))
    |> maybe_put(:timeout, Keyword.get(config, :timeout))
    |> then(fn opts ->
      if Keyword.get(config, :ssl, false), do: Keyword.put(opts, :ssl, true), else: opts
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Parses a comma-separated string of `host:port` sentinel addresses into a
  list of maps expected by Redix.

      iex> WhisprMessaging.RedisConfig.parse_sentinels("s1:26379,s2:26379")
      [%{host: "s1", port: 26379}, %{host: "s2", port: 26379}]
  """
  @spec parse_sentinels(String.t()) :: [%{host: String.t(), port: non_neg_integer()}]
  def parse_sentinels(sentinels_str) do
    sentinels_str
    |> String.split(",")
    |> Enum.map(fn entry ->
      case String.split(String.trim(entry), ":") do
        [host, port] -> [host: host, port: String.to_integer(port)]
        [host] -> [host: host, port: 26_379]
      end
    end)
  end

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp log_mode("sentinel", opts) do
    sentinel = Keyword.get(opts, :sentinel, [])
    sentinels = Keyword.get(sentinel, :sentinels, [])
    master = Keyword.get(sentinel, :group, "?")

    sentinels_str =
      Enum.map_join(sentinels, ", ", fn s -> "#{s[:host]}:#{s[:port]}" end)

    Logger.info("Redis mode: sentinel (master: #{master}, sentinels: #{sentinels_str})")
  end

  defp log_mode(_, opts) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 6379)
    db = Keyword.get(opts, :database, 0)
    Logger.info("Redis mode: direct (#{host}:#{port}/#{db})")
  end
end
