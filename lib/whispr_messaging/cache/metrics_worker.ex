defmodule WhisprMessaging.Cache.MetricsWorker do
  @moduledoc """
  Worker pour collecter et publier les métriques du cache Redis
  """
  
  use GenServer
  
  alias WhisprMessaging.Cache.RedisConnection
  # alias WhisprMessaging.Cache.{PresenceCache, SessionCache} (non utilisés actuellement)
  
  require Logger

  @metrics_interval 60_000 # 1 minute
  @metrics_key "cache:metrics:stats"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Cache metrics worker started")
    schedule_metrics_collection()
    
    # Initialiser les compteurs ETS pour des métriques locales rapides
    :ets.new(:cache_metrics, [:named_table, :public, :set])
    
    {:ok, %{
      last_collection: DateTime.utc_now(),
      total_operations: 0
    }}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    Logger.debug("Collecting cache metrics")
    
    start_time = System.monotonic_time(:millisecond)
    
    metrics = collect_all_metrics()
    
    # Stocker les métriques dans Redis pour partage entre nœuds
    store_metrics(metrics)
    
    # Publier via Telemetry pour monitoring externe
    publish_telemetry_metrics(metrics)
    
    end_time = System.monotonic_time(:millisecond)
    collection_duration = end_time - start_time
    
    Logger.debug("Metrics collection completed", %{
      duration_ms: collection_duration,
      metrics_count: map_size(metrics)
    })
    
    schedule_metrics_collection()
    
    new_state = %{
      last_collection: DateTime.utc_now(),
      total_operations: state.total_operations + 1
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    # Récupérer les métriques actuelles
    current_metrics = get_cached_metrics()
    {:reply, current_metrics, state}
  end

  @impl true
  def handle_call({:increment_counter, counter_name}, _from, state) do
    # Incrémenter un compteur local (rapide)
    :ets.update_counter(:cache_metrics, counter_name, 1, {counter_name, 0})
    {:reply, :ok, state}
  end

  ## Collection de métriques

  defp collect_all_metrics do
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      node: Node.self() |> Atom.to_string(),
      
      # Métriques Redis générales
      redis_health: collect_redis_health(),
      connection_pools: collect_pool_stats(),
      
      # Métriques par type de cache
      presence_metrics: collect_presence_metrics(),
      session_metrics: collect_session_metrics(),
      message_queue_metrics: collect_message_queue_metrics(),
      
      # Métriques de performance locales
      local_counters: collect_local_counters(),
      
      # Métriques système
      memory_usage: collect_memory_metrics()
    }
  end

  defp collect_redis_health do
    RedisConnection.health_check()
  end

  defp collect_pool_stats do
    RedisConnection.pool_stats()
  end

  defp collect_presence_metrics do
    %{
      online_users_count: count_keys_with_pattern("presence:user:*"),
      active_conversations_count: count_keys_with_pattern("presence:conversation:*"),
      typing_indicators_count: count_keys_with_pattern("typing:conversation:*")
    }
  end

  defp collect_session_metrics do
    %{
      active_sessions_count: count_keys_with_pattern("session:*"),
      cached_preferences_count: count_keys_with_pattern("preferences:user:*")
    }
  end

  defp collect_message_queue_metrics do
    %{
      message_queues_count: count_keys_with_pattern("delivery:queue:*"),
      sync_states_count: count_keys_with_pattern("sync:state:user:*"),
      active_sync_locks_count: count_keys_with_pattern("sync:lock:*"),
      pending_sync_changes_count: count_keys_with_pattern("sync:pending:*")
    }
  end

  defp collect_local_counters do
    try do
      :ets.tab2list(:cache_metrics) |> Enum.into(%{})
    rescue
      ArgumentError -> %{}
    end
  end

  defp collect_memory_metrics do
    %{
      total_memory: :erlang.memory(:total),
      processes_memory: :erlang.memory(:processes),
      system_memory: :erlang.memory(:system),
      ets_memory: :erlang.memory(:ets)
    }
  end

  ## Fonctions utilitaires

  defp count_keys_with_pattern(pattern) do
    case scan_keys_with_pattern(pattern) do
      {:ok, keys} -> length(keys)
      {:error, _} -> 0
    end
  end

  defp scan_keys_with_pattern(pattern) do
    # Utiliser le pool principal par défaut
    scan_keys(:main_pool, 0, pattern, [])
  end

  defp scan_keys(pool, cursor, pattern, acc) do
    case RedisConnection.execute_command(pool, "SCAN", [cursor, "MATCH", pattern, "COUNT", "1000"]) do
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

  defp store_metrics(metrics) do
    try do
      # Filtrer les erreurs avant l'encodage JSON
      clean_metrics = sanitize_metrics_for_json(metrics)
      metrics_json = Jason.encode!(clean_metrics)
      
      case RedisConnection.command("SETEX", [@metrics_key, 300, metrics_json]) do
        {:ok, "OK"} ->
          :ok
        {:error, reason} ->
          Logger.error("Failed to store metrics in Redis: #{inspect(reason)}")
          :error
      end
    rescue
      error ->
        Logger.error("Failed to encode metrics: #{inspect(error)}")
        :error
    end
  end
  
  # Nettoie les métriques pour éviter les erreurs d'encodage JSON
  defp sanitize_metrics_for_json(metrics) when is_map(metrics) do
    metrics
    |> Enum.map(fn {key, value} -> {key, sanitize_value(value)} end)
    |> Enum.into(%{})
  end
  
  defp sanitize_value({:error, _reason}), do: "error"
  defp sanitize_value({:ok, value}), do: value
  defp sanitize_value(value) when is_tuple(value), do: "tuple_value"
  defp sanitize_value(value), do: value

  defp get_cached_metrics do
    case RedisConnection.command("GET", [@metrics_key]) do
      {:ok, nil} ->
        %{}
      {:ok, metrics_json} ->
        case Jason.decode(metrics_json) do
          {:ok, metrics} -> metrics
          {:error, _} -> %{}
        end
      {:error, _} ->
        %{}
    end
  end

  defp publish_telemetry_metrics(metrics) do
    # Publier les métriques via Telemetry pour Prometheus, etc.
    :telemetry.execute(
      [:whispr_messaging, :cache, :metrics],
      %{
        online_users: metrics.presence_metrics.online_users_count,
        active_sessions: metrics.session_metrics.active_sessions_count,
        message_queues: metrics.message_queue_metrics.message_queues_count,
        memory_total: metrics.memory_usage.total_memory
      },
      %{node: metrics.node, timestamp: metrics.timestamp}
    )
    
    # Publier l'état de santé Redis
    case metrics.redis_health do
      %{main_pool: :healthy, session_pool: :healthy, queue_pool: :healthy} ->
        :telemetry.execute([:whispr_messaging, :cache, :redis_health], %{status: 1}, %{})
        
      _ ->
        :telemetry.execute([:whispr_messaging, :cache, :redis_health], %{status: 0}, %{})
    end
  end

  defp schedule_metrics_collection do
    Process.send_after(self(), :collect_metrics, @metrics_interval)
  end

  ## API publique

  def get_current_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  def increment_counter(counter_name) do
    GenServer.call(__MODULE__, {:increment_counter, counter_name})
  end

  def trigger_collection do
    send(__MODULE__, :collect_metrics)
    :ok
  end

  ## Métriques de convenance (peuvent être appelées directement)

  def record_cache_hit(cache_type) do
    increment_counter(:"#{cache_type}_hits")
  end

  def record_cache_miss(cache_type) do
    increment_counter(:"#{cache_type}_misses")
  end

  def record_cache_operation(operation_type) do
    increment_counter(:"cache_#{operation_type}")
  end
end
