defmodule WhisprMessaging.Cache do
  @moduledoc """
  Redis-based caching layer for frequently accessed data.

  Implements cache-aside pattern with TTL management.
  """

  require Logger

  # 5 minutes
  @default_ttl 300

  @doc """
  Gets value from cache. Returns {:ok, value} or {:error, :not_found}.
  """
  def get(key) do
    case Redix.command(:redix, ["GET", cache_key(key)]) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, value}
        end

      {:error, reason} ->
        Logger.error("Redis GET error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sets value in cache with optional TTL (seconds).
  """
  def set(key, value, ttl \\ @default_ttl) do
    encoded_value =
      case Jason.encode(value) do
        {:ok, json} -> json
        {:error, _} -> to_string(value)
      end

    case Redix.command(:redix, ["SETEX", cache_key(key), ttl, encoded_value]) do
      {:ok, "OK"} ->
        :ok

      {:error, reason} ->
        Logger.error("Redis SET error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Deletes key from cache.
  """
  def delete(key) do
    case Redix.command(:redix, ["DEL", cache_key(key)]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Redis DEL error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets value from cache or executes function and caches result.
  """
  def fetch(key, fallback_fun, ttl \\ @default_ttl) do
    case get(key) do
      {:ok, value} ->
        Logger.debug("Cache HIT: #{key}")
        {:ok, value}

      {:error, :not_found} ->
        Logger.debug("Cache MISS: #{key}")

        case fallback_fun.() do
          {:ok, value} = result ->
            set(key, value, ttl)
            result

          error ->
            error
        end
    end
  end

  @doc """
  Invalidates cache keys matching pattern.
  """
  def invalidate_pattern(pattern) do
    case Redix.command(:redix, ["KEYS", cache_key(pattern)]) do
      {:ok, keys} when keys != [] ->
        Redix.command(:redix, ["DEL" | keys])
        Logger.info("Invalidated #{length(keys)} cache keys for pattern: #{pattern}")
        :ok

      {:ok, []} ->
        :ok

      {:error, reason} ->
        Logger.error("Redis KEYS error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Cache key helpers for specific entities

  def conversation_key(conversation_id), do: "conversation:#{conversation_id}"
  def message_key(message_id), do: "message:#{message_id}"
  def user_conversations_key(user_id), do: "user:#{user_id}:conversations"
  def conversation_messages_key(conversation_id), do: "conversation:#{conversation_id}:messages"

  # Private functions

  defp cache_key(key), do: "cache:#{key}"
end
