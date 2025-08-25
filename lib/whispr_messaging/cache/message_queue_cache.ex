defmodule WhisprMessaging.Cache.MessageQueueCache do
  @moduledoc """
  Cache des files d'attente de messages et synchronisation multi-appareils
  selon les spécifications 7_multi_device_sync.md
  """
  
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  @message_delivery_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :message_delivery], 604800) # 7 jours
  @sync_state_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :sync_state], 600) # 10 minutes
  @sync_pending_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :sync_pending], 86400) # 24 heures
  @sync_lock_ttl Application.compile_env(:whispr_messaging, [:redis_ttl, :sync_lock], 30) # 30 secondes

  ## File d'Attente de Messages

  @doc """
  Ajouter un message à la file d'attente d'un utilisateur (hors ligne)
  """
  def queue_message_for_user(user_id, message_data, priority \\ 1) do
    key = delivery_queue_key(user_id)
    
    # Score = timestamp + priorité (priorité plus haute = score plus bas)
    score = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(priority * 1000)
    message_json = Jason.encode!(message_data)
    
    commands = [
      ["ZADD", key, score, message_json],
      ["EXPIRE", key, @message_delivery_ttl]
    ]
    
    case RedisConnection.pipeline(:queue_pool, commands) do
      {:ok, _results} ->
        Logger.debug("Message queued for user", %{
          user_id: user_id,
          message_id: message_data[:id],
          priority: priority
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to queue message for user", %{
          user_id: user_id,
          message_id: message_data[:id],
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer les messages en attente pour un utilisateur
  """
  def get_pending_messages(user_id, limit \\ 100) do
    key = delivery_queue_key(user_id)
    
    # Récupérer les messages par ordre de priorité/timestamp
    case RedisConnection.queue_command("ZRANGE", [key, "0", to_string(limit - 1), "WITHSCORES"]) do
      {:ok, []} ->
        {:ok, []}
        
      {:ok, results} when is_list(results) ->
        messages = 
          results
          |> Enum.chunk_every(2)
          |> Enum.map(fn [message_json, score] ->
            case Jason.decode(message_json) do
              {:ok, message_data} ->
                %{
                  message: message_data,
                  score: String.to_float(score),
                  queued_at: extract_timestamp_from_score(score)
                }
              {:error, _} ->
                Logger.warning("Failed to decode queued message", %{
                  user_id: user_id,
                  message_json: message_json
                })
                nil
            end
          end)
          |> Enum.filter(& &1)
        
        {:ok, messages}
        
      {:error, reason} ->
        Logger.error("Failed to get pending messages", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer des messages de la file d'attente après livraison
  """
  def remove_delivered_messages(user_id, message_ids) when is_list(message_ids) do
    key = delivery_queue_key(user_id)
    
    # Récupérer tous les messages pour filtrer par ID
    case RedisConnection.queue_command("ZRANGE", [key, "0", "-1"]) do
      {:ok, queued_messages} ->
        messages_to_remove = 
          queued_messages
          |> Enum.filter(fn message_json ->
            case Jason.decode(message_json) do
              {:ok, %{"id" => msg_id}} -> msg_id in message_ids
              _ -> false
            end
          end)
        
        if not Enum.empty?(messages_to_remove) do
          remove_commands = Enum.map(messages_to_remove, fn msg -> ["ZREM", key, msg] end)
          
          case RedisConnection.pipeline(:queue_pool, remove_commands) do
            {:ok, _results} ->
              Logger.debug("Delivered messages removed from queue", %{
                user_id: user_id,
                removed_count: length(messages_to_remove)
              })
              :ok
              
            {:error, reason} ->
              {:error, reason}
          end
        else
          :ok
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Synchronisation Multi-Appareils

  @doc """
  Mettre à jour l'état de synchronisation d'un utilisateur
  """
  def update_sync_state(user_id, sync_state) do
    key = sync_state_key(user_id)
    
    state_data = %{
      devices: sync_state.devices || [],
      pending_changes: sync_state.pending_changes || 0,
      last_activity: DateTime.utc_now() |> DateTime.to_iso8601(),
      sync_version: sync_state.sync_version || 1
    }
    
    commands = [
      ["SET", key, Jason.encode!(state_data)],
      ["EXPIRE", key, @sync_state_ttl]
    ]
    
    case RedisConnection.pipeline(:queue_pool, commands) do
      {:ok, _results} ->
        Logger.debug("Sync state updated", %{
          user_id: user_id,
          devices_count: length(state_data.devices)
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to update sync state", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer l'état de synchronisation d'un utilisateur
  """
  def get_sync_state(user_id) do
    key = sync_state_key(user_id)
    
    case RedisConnection.queue_command("GET", [key]) do
      {:ok, nil} ->
        {:ok, nil}
        
      {:ok, state_json} ->
        case Jason.decode(state_json) do
          {:ok, state_data} ->
            {:ok, state_data}
          {:error, _} ->
            Logger.warning("Failed to decode sync state", %{user_id: user_id})
            {:ok, nil}
        end
        
      {:error, reason} ->
        Logger.error("Failed to get sync state", %{
          user_id: user_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Ajouter un changement à la file d'attente de synchronisation d'un appareil
  """
  def add_pending_change(user_id, device_id, change_data, priority \\ 1) do
    key = sync_pending_key(user_id, device_id)
    
    change_info = %{
      change_id: change_data.change_id || UUID.uuid4(),
      type: change_data.type,
      data: change_data.data,
      priority: priority,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    # Utiliser une liste ordonnée par priorité
    score = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(priority * 1000)
    
    commands = [
      ["ZADD", key, score, Jason.encode!(change_info)],
      ["EXPIRE", key, @sync_pending_ttl]
    ]
    
    case RedisConnection.pipeline(:queue_pool, commands) do
      {:ok, _results} ->
        Logger.debug("Pending change added", %{
          user_id: user_id,
          device_id: device_id,
          change_type: change_data.type,
          change_id: change_info.change_id
        })
        {:ok, change_info.change_id}
        
      {:error, reason} ->
        Logger.error("Failed to add pending change", %{
          user_id: user_id,
          device_id: device_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Récupérer les changements en attente pour un appareil
  """
  def get_pending_changes(user_id, device_id, limit \\ 50) do
    key = sync_pending_key(user_id, device_id)
    
    case RedisConnection.queue_command("ZRANGE", [key, "0", to_string(limit - 1)]) do
      {:ok, []} ->
        {:ok, []}
        
      {:ok, change_jsons} when is_list(change_jsons) ->
        changes = 
          change_jsons
          |> Enum.map(fn change_json ->
            case Jason.decode(change_json) do
              {:ok, change_data} -> change_data
              {:error, _} -> nil
            end
          end)
          |> Enum.filter(& &1)
        
        {:ok, changes}
        
      {:error, reason} ->
        Logger.error("Failed to get pending changes", %{
          user_id: user_id,
          device_id: device_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Supprimer des changements traités de la file d'attente
  """
  def remove_processed_changes(user_id, device_id, change_ids) when is_list(change_ids) do
    key = sync_pending_key(user_id, device_id)
    
    # Récupérer tous les changements pour filtrer par ID
    case RedisConnection.queue_command("ZRANGE", [key, "0", "-1"]) do
      {:ok, change_jsons} ->
        changes_to_remove = 
          change_jsons
          |> Enum.filter(fn change_json ->
            case Jason.decode(change_json) do
              {:ok, %{"change_id" => change_id}} -> change_id in change_ids
              _ -> false
            end
          end)
        
        if not Enum.empty?(changes_to_remove) do
          remove_commands = Enum.map(changes_to_remove, fn change -> ["ZREM", key, change] end)
          
          case RedisConnection.pipeline(:queue_pool, remove_commands) do
            {:ok, _results} ->
              Logger.debug("Processed changes removed", %{
                user_id: user_id,
                device_id: device_id,
                removed_count: length(changes_to_remove)
              })
              :ok
              
            {:error, reason} ->
              {:error, reason}
          end
        else
          :ok
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Verrous de Synchronisation

  @doc """
  Acquérir un verrou de synchronisation
  """
  def acquire_sync_lock(user_id, resource, operation, device_id) do
    key = sync_lock_key(user_id, resource)
    lock_id = UUID.uuid4()
    
    lock_data = %{
      lock_id: lock_id,
      device_id: device_id,
      operation: operation,
      acquired_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    # Utiliser SET avec NX (seulement si n'existe pas) et EX (expiration)
    case RedisConnection.queue_command("SET", [key, Jason.encode!(lock_data), "NX", "EX", @sync_lock_ttl]) do
      {:ok, "OK"} ->
        Logger.debug("Sync lock acquired", %{
          user_id: user_id,
          resource: resource,
          lock_id: lock_id,
          device_id: device_id
        })
        {:ok, lock_id}
        
      {:ok, nil} ->
        # Verrou déjà pris
        {:error, :lock_already_acquired}
        
      {:error, reason} ->
        Logger.error("Failed to acquire sync lock", %{
          user_id: user_id,
          resource: resource,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Libérer un verrou de synchronisation
  """
  def release_sync_lock(user_id, resource, lock_id) do
    key = sync_lock_key(user_id, resource)
    
    # Script Lua pour vérifier le lock_id avant suppression (atomique)
    lua_script = """
    local current = redis.call('GET', KEYS[1])
    if current then
      local lock_data = cjson.decode(current)
      if lock_data.lock_id == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      end
    end
    return 0
    """
    
    case RedisConnection.queue_command("EVAL", [lua_script, "1", key, lock_id]) do
      {:ok, 1} ->
        Logger.debug("Sync lock released", %{
          user_id: user_id,
          resource: resource,
          lock_id: lock_id
        })
        :ok
        
      {:ok, 0} ->
        Logger.warning("Attempted to release non-existent or wrong lock", %{
          user_id: user_id,
          resource: resource,
          lock_id: lock_id
        })
        {:error, :lock_not_found}
        
      {:error, reason} ->
        Logger.error("Failed to release sync lock", %{
          user_id: user_id,
          resource: resource,
          lock_id: lock_id,
          error: reason
        })
        {:error, reason}
    end
  end

  ## Fonctions utilitaires

  defp delivery_queue_key(user_id), do: "delivery:queue:#{user_id}"
  defp sync_state_key(user_id), do: "sync:state:user:#{user_id}"
  defp sync_pending_key(user_id, device_id), do: "sync:pending:#{user_id}:#{device_id}"
  defp sync_lock_key(user_id, resource), do: "sync:lock:#{user_id}:#{resource}"

  defp extract_timestamp_from_score(score) when is_binary(score) do
    score
    |> String.to_float()
    |> trunc()
    |> DateTime.from_unix()
    |> case do
      {:ok, datetime} -> datetime
      {:error, _} -> DateTime.utc_now()
    end
  end
end
