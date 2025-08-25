defmodule WhisprMessaging.Cache.SessionCache do
  @moduledoc """
  Cache de sessions WebSocket et préférences utilisateur
  selon les spécifications de cache distribué
  """
  
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  @session_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :user_session], 1800)
  @preferences_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :user_preferences], 3600)

  ## Sessions WebSocket

  @doc """
  Stocker une session WebSocket active
  """
  def store_session(session_id, session_data) do
    key = session_key(session_id)
    
    session_info = %{
      user_id: session_data.user_id,
      device_id: session_data.device_id,
      ip_address: session_data[:ip_address],
      user_agent: session_data[:user_agent],
      connected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      channel_subscriptions: session_data[:channel_subscriptions] || [],
      node: Node.self() |> Atom.to_string()
    }
    
    commands = [
      ["HSET", key] ++ flatten_hash(session_info),
      ["EXPIRE", key, @session_ttl]
    ]
    
    case RedisConnection.pipeline(:session_pool, commands) do
      {:ok, _results} ->
        Logger.debug("Session stored", %{
          session_id: session_id,
          user_id: session_data.user_id,
          ttl: @session_ttl
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to store session", %{
          session_id: session_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer une session WebSocket
  """
  def get_session(session_id) do
    key = session_key(session_id)
    
    case RedisConnection.session_command("HGETALL", [key]) do
      {:ok, []} ->
        {:ok, nil}
        
      {:ok, fields} when is_list(fields) ->
        session_data = parse_redis_hash(fields)
        {:ok, session_data}
        
      {:error, reason} ->
        Logger.error("Failed to get session", %{
          session_id: session_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Mettre à jour les souscriptions d'une session
  """
  def update_session_subscriptions(session_id, channel_subscriptions) do
    key = session_key(session_id)
    
    case RedisConnection.session_command("HSET", [key, "channel_subscriptions", Jason.encode!(channel_subscriptions)]) do
      {:ok, _} ->
        # Renouveler le TTL
        RedisConnection.session_command("EXPIRE", [key, @session_ttl])
        Logger.debug("Session subscriptions updated", %{
          session_id: session_id,
          subscriptions_count: length(channel_subscriptions)
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to update session subscriptions", %{
          session_id: session_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer une session
  """
  def remove_session(session_id) do
    key = session_key(session_id)
    
    case RedisConnection.session_command("DEL", [key]) do
      {:ok, _count} ->
        Logger.debug("Session removed", %{session_id: session_id})
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to remove session", %{
          session_id: session_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer toutes les sessions d'un utilisateur
  """
  def get_user_sessions(user_id) do
    pattern = "session:*"
    
    case scan_keys_with_pattern(pattern) do
      {:ok, session_keys} ->
        # Récupérer les données de toutes les sessions
        commands = Enum.map(session_keys, fn key -> ["HGETALL", key] end)
        
        case RedisConnection.pipeline(:session_pool, commands) do
          {:ok, results} ->
            user_sessions = 
              session_keys
              |> Enum.zip(results)
              |> Enum.filter(fn {_key, fields} -> fields != [] end)
              |> Enum.map(fn {key, fields} ->
                session_data = parse_redis_hash(fields)
                session_id = String.replace(key, "session:", "")
                Map.put(session_data, "session_id", session_id)
              end)
              |> Enum.filter(fn session -> session["user_id"] == user_id end)
            
            {:ok, user_sessions}
            
          {:error, reason} ->
            {:error, reason}
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Préférences Utilisateur

  @doc """
  Stocker les préférences d'un utilisateur
  """
  def store_user_preferences(user_id, preferences) when is_map(preferences) do
    key = preferences_key(user_id)
    
    preferences_data = %{
      notification_preferences: preferences[:notifications] || %{},
      privacy_settings: preferences[:privacy] || %{},
      ui_preferences: preferences[:ui] || %{},
      conversation_settings: preferences[:conversations] || %{},
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    commands = [
      ["HSET", key] ++ flatten_hash(preferences_data),
      ["EXPIRE", key, @preferences_ttl]
    ]
    
    case RedisConnection.pipeline(:main_pool, commands) do
      {:ok, _results} ->
        Logger.debug("User preferences stored", %{
          user_id: user_id,
          preferences_keys: Map.keys(preferences)
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to store user preferences", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer les préférences d'un utilisateur
  """
  def get_user_preferences(user_id) do
    key = preferences_key(user_id)
    
    case RedisConnection.command("HGETALL", [key]) do
      {:ok, []} ->
        {:ok, nil} # Pas de préférences en cache
        
      {:ok, fields} when is_list(fields) ->
        preferences = parse_redis_hash(fields)
        {:ok, preferences}
        
      {:error, reason} ->
        Logger.error("Failed to get user preferences", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Mettre à jour une préférence spécifique
  """
  def update_user_preference(user_id, preference_key, value) do
    key = preferences_key(user_id)
    
    value_json = Jason.encode!(value)
    
    commands = [
      ["HSET", key, preference_key, value_json],
      ["HSET", key, "updated_at", DateTime.utc_now() |> DateTime.to_iso8601()],
      ["EXPIRE", key, @preferences_ttl]
    ]
    
    case RedisConnection.pipeline(:main_pool, commands) do
      {:ok, _results} ->
        Logger.debug("User preference updated", %{
          user_id: user_id,
          preference_key: preference_key
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to update user preference", %{
          user_id: user_id,
          preference_key: preference_key,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer les préférences d'un utilisateur du cache
  """
  def remove_user_preferences(user_id) do
    key = preferences_key(user_id)
    
    case RedisConnection.command("DEL", [key]) do
      {:ok, _count} ->
        Logger.debug("User preferences removed from cache", %{user_id: user_id})
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to remove user preferences", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  ## Fonctions utilitaires

  defp session_key(session_id), do: "session:#{session_id}"
  defp preferences_key(user_id), do: "preferences:user:#{user_id}"

  defp flatten_hash(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      value_str = if is_binary(value), do: value, else: Jason.encode!(value)
      [to_string(key), value_str]
    end)
  end

  defp parse_redis_hash([]), do: nil
  defp parse_redis_hash(fields) when is_list(fields) do
    fields
    |> Enum.chunk_every(2)
    |> Enum.map(fn [key, value] ->
      # Essayer de décoder JSON, sinon garder comme string
      parsed_value = case Jason.decode(value) do
        {:ok, decoded} -> decoded
        {:error, _} -> value
      end
      {key, parsed_value}
    end)
    |> Enum.into(%{})
  end

  defp scan_keys_with_pattern(pattern) do
    # Utiliser SCAN pour éviter de bloquer Redis avec KEYS
    scan_keys(0, pattern, [])
  end

  defp scan_keys(cursor, pattern, acc) do
    case RedisConnection.session_command("SCAN", [cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [next_cursor, keys]} ->
        new_acc = acc ++ keys
        
        if next_cursor == "0" do
          {:ok, new_acc}
        else
          scan_keys(String.to_integer(next_cursor), pattern, new_acc)
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end
end
