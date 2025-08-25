defmodule WhisprMessaging.Cache.CleanupWorker do
  @moduledoc """
  Worker pour le nettoyage automatique des caches expirés
  et la maintenance des structures Redis
  """
  
  use GenServer
  
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  @cleanup_interval 300_000 # 5 minutes
  # @expired_keys_limit 1000 # Non utilisé actuellement

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Cache cleanup worker started")
    schedule_cleanup()
    {:ok, %{last_cleanup: DateTime.utc_now(), cleaned_keys: 0}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    Logger.debug("Starting cache cleanup cycle")
    
    start_time = System.monotonic_time(:millisecond)
    
    cleanup_results = %{
      expired_sessions: cleanup_expired_sessions(),
      expired_presence: cleanup_expired_presence(),
      expired_typing_indicators: cleanup_expired_typing(),
      expired_message_queues: cleanup_expired_message_queues(),
      expired_sync_locks: cleanup_expired_sync_locks()
    }
    
    end_time = System.monotonic_time(:millisecond)
    cleanup_duration = end_time - start_time
    
    total_cleaned = 
      cleanup_results
      |> Map.values()
      |> Enum.sum()
    
    Logger.info("Cache cleanup completed", %{
      duration_ms: cleanup_duration,
      total_cleaned: total_cleaned,
      breakdown: cleanup_results
    })
    
    schedule_cleanup()
    
    new_state = %{
      last_cleanup: DateTime.utc_now(),
      cleaned_keys: state.cleaned_keys + total_cleaned
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      last_cleanup: state.last_cleanup,
      total_cleaned_keys: state.cleaned_keys,
      next_cleanup_in: @cleanup_interval
    }
    {:reply, stats, state}
  end

  ## Fonctions de nettoyage

  defp cleanup_expired_sessions do
    Logger.debug("Cleaning up expired sessions")
    
    case scan_and_cleanup("session:*", &validate_session/1) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("Failed to cleanup sessions", %{error: reason})
        0
    end
  end

  defp cleanup_expired_presence do
    Logger.debug("Cleaning up expired presence data")
    
    case scan_and_cleanup("presence:user:*", &validate_presence/1) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("Failed to cleanup presence", %{error: reason})
        0
    end
  end

  defp cleanup_expired_typing do
    Logger.debug("Cleaning up expired typing indicators")
    
    case scan_and_cleanup("typing:conversation:*", &validate_typing/1) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("Failed to cleanup typing indicators", %{error: reason})
        0
    end
  end

  defp cleanup_expired_message_queues do
    Logger.debug("Cleaning up old message queues")
    
    # Nettoyer les messages livrés depuis plus de 24h
    case scan_and_cleanup("delivery:queue:*", &cleanup_old_messages/1) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("Failed to cleanup message queues", %{error: reason})
        0
    end
  end

  defp cleanup_expired_sync_locks do
    Logger.debug("Cleaning up expired sync locks")
    
    case scan_and_cleanup("sync:lock:*", &validate_sync_lock/1) do
      {:ok, count} -> count
      {:error, reason} ->
        Logger.error("Failed to cleanup sync locks", %{error: reason})
        0
    end
  end

  ## Fonctions utilitaires

  defp scan_and_cleanup(pattern, validator_fn) do
    case scan_keys_with_pattern(pattern) do
      {:ok, keys} ->
        cleaned_count = 
          keys
          |> Enum.chunk_every(100) # Traiter par lots
          |> Enum.map(&process_key_batch(&1, validator_fn))
          |> Enum.sum()
        
        {:ok, cleaned_count}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_key_batch(keys, validator_fn) do
    keys
    |> Enum.map(validator_fn)
    |> Enum.count(fn result -> result == :delete end)
  end

  defp validate_session(key) do
    case RedisConnection.session_command("HGET", [key, "connected_at"]) do
      {:ok, nil} ->
        # Session sans timestamp = invalide
        delete_key(key)
        :delete
        
      {:ok, connected_at_str} ->
        case DateTime.from_iso8601(connected_at_str) do
          {:ok, connected_at, _} ->
            # Supprimer les sessions de plus de 24h
            if DateTime.diff(DateTime.utc_now(), connected_at, :second) > 86400 do
              delete_key(key)
              :delete
            else
              :keep
            end
            
          {:error, _} ->
            # Timestamp invalide
            delete_key(key)
            :delete
        end
        
      {:error, _} ->
        :keep
    end
  end

  defp validate_presence(key) do
    case RedisConnection.session_command("HGET", [key, "last_activity"]) do
      {:ok, nil} ->
        delete_key(key)
        :delete
        
      {:ok, last_activity_str} ->
        case DateTime.from_iso8601(last_activity_str) do
          {:ok, last_activity, _} ->
            # Supprimer les présences inactives depuis plus de 1h
            if DateTime.diff(DateTime.utc_now(), last_activity, :second) > 3600 do
              delete_key(key)
              :delete
            else
              :keep
            end
            
          {:error, _} ->
            delete_key(key)
            :delete
        end
        
      {:error, _} ->
        :keep
    end
  end

  defp validate_typing(key) do
    case RedisConnection.session_command("HGETALL", [key]) do
      {:ok, []} ->
        :keep # Déjà vide
        
      {:ok, fields} when is_list(fields) ->
        # Vérifier si les indicateurs sont expirés
        now = DateTime.utc_now()
        
        expired_users = 
          fields
          |> Enum.chunk_every(2)
          |> Enum.filter(fn [_user_id, data_json] ->
            case Jason.decode(data_json) do
              {:ok, %{"started_at" => started_at_str}} ->
                case DateTime.from_iso8601(started_at_str) do
                  {:ok, started_at, _} ->
                    DateTime.diff(now, started_at, :second) > 30 # 30 secondes
                  {:error, _} ->
                    true # Données corrompues
                end
              _ ->
                true # Données corrompues
            end
          end)
          |> Enum.map(fn [user_id, _] -> user_id end)
        
        # Supprimer les utilisateurs expirés
        if not Enum.empty?(expired_users) do
          RedisConnection.session_command("HDEL", [key | expired_users])
        end
        
        :keep
        
      {:error, _} ->
        :keep
    end
  end

  defp cleanup_old_messages(key) do
    # Supprimer les messages livrés il y a plus de 7 jours
    cutoff_time = DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.to_unix()
    
    case RedisConnection.queue_command("ZREMRANGEBYSCORE", [key, "-inf", cutoff_time]) do
      {:ok, removed_count} when removed_count > 0 ->
        Logger.debug("Removed old messages from queue", %{
          queue_key: key,
          removed_count: removed_count
        })
        :cleanup
        
      _ ->
        :keep
    end
  end

  defp validate_sync_lock(key) do
    case RedisConnection.queue_command("GET", [key]) do
      {:ok, nil} ->
        :keep # Déjà expiré naturellement
        
      {:ok, lock_data_json} ->
        case Jason.decode(lock_data_json) do
          {:ok, %{"acquired_at" => acquired_at_str}} ->
            case DateTime.from_iso8601(acquired_at_str) do
              {:ok, acquired_at, _} ->
                # Supprimer les verrous de plus de 5 minutes (sécurité)
                if DateTime.diff(DateTime.utc_now(), acquired_at, :second) > 300 do
                  delete_key(key)
                  :delete
                else
                  :keep
                end
                
              {:error, _} ->
                delete_key(key)
                :delete
            end
            
          _ ->
            delete_key(key)
            :delete
        end
        
      {:error, _} ->
        :keep
    end
  end

  defp delete_key(key) do
    # Déterminer le bon pool selon le préfixe de clé
    _pool = case String.starts_with?(key, "session:") or String.starts_with?(key, "presence:") do
      true -> :session_pool
      false -> :main_pool
    end
    
    RedisConnection.command("DEL", [key])
  end

  defp scan_keys_with_pattern(pattern) do
    scan_keys(:main_pool, 0, pattern, [])
  end

  defp scan_keys(pool, cursor, pattern, acc) do
    case RedisConnection.execute_command(pool, "SCAN", [cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [next_cursor, keys]} ->
        new_acc = acc ++ keys
        
        if next_cursor == "0" do
          {:ok, new_acc}
        else
          scan_keys(pool, String.to_integer(next_cursor), pattern, new_acc)
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  ## API publique

  def get_stats do
    GenServer.call(__MODULE__, :stats)
  end

  def trigger_cleanup do
    send(__MODULE__, :cleanup)
    :ok
  end
end
