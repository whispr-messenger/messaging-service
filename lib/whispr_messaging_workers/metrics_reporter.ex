defmodule WhisprMessaging.WorkersMetricsReporter do
  @moduledoc """
  Worker de rapports de métriques selon system_design.md
  Collecte et reporte les métriques de performance et business.
  """
  use GenServer
  
  require Logger
  
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Programmer la première collecte de métriques
    schedule_metrics_collection()
    
    state = %{
      last_collection: DateTime.utc_now(),
      collections_count: 0
    }
    
    {:ok, state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    collect_and_report_metrics()
    
    schedule_metrics_collection()
    
    new_state = %{state | 
      last_collection: DateTime.utc_now(),
      collections_count: state.collections_count + 1
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_metrics_stats, _from, state) do
    stats = %{
      last_collection: state.last_collection,
      total_collections: state.collections_count
    }
    
    {:reply, stats, state}
  end

  ## Private Functions

  defp collect_and_report_metrics do
    try do
      # Collecter les métriques de performance
      performance_metrics = collect_performance_metrics()
      
      # Collecter les métriques business
      business_metrics = collect_business_metrics()
      
      # Rapporter à Telemetry
      :telemetry.execute([:whispr_messaging, :performance], performance_metrics)
      :telemetry.execute([:whispr_messaging, :business], business_metrics)
      
      Logger.debug("Metrics collection completed")
    rescue
      error ->
        Logger.warning("Metrics collection failed: #{inspect(error)}")
    end
  end

  defp collect_performance_metrics do
    %{
      # Métriques de processus
      active_conversations: count_active_conversations(),
      total_processes: length(Process.list()),
      memory_usage: :erlang.memory(:total),
      
      # Métriques de performance OTP
      message_queue_len: get_message_queue_lengths(),
      heap_size: get_heap_sizes(),
      
      # Métriques Redis
      redis_connections: count_redis_connections(),
      redis_memory: get_redis_memory_usage()
    }
  end

  defp collect_business_metrics do
    last_hour = DateTime.utc_now() |> DateTime.add(-1, :hour)
    last_day = DateTime.utc_now() |> DateTime.add(-1, :day)
    
    %{
      # Métriques de conversations
      total_conversations: safe_call(Conversations, :count_total_conversations, [], 0),
      active_conversations_24h: safe_call(Conversations, :count_active_since, [last_day], 0),
      
      # Métriques de messages
      messages_sent_1h: safe_call(Messages, :count_messages_since, [last_hour], 0),
      messages_sent_24h: safe_call(Messages, :count_messages_since, [last_day], 0),
      
      # Métriques d'utilisateurs
      active_users_24h: count_active_users_since(last_day),
      
      # Métriques de performance
      avg_message_size: safe_call(Messages, :get_average_message_size, [], 0),
      p95_delivery_time: get_p95_delivery_time()
    }
  end

  defp count_active_conversations do
    case WhisprMessaging.Conversations.Supervisor.list_active_conversations() do
      conversations when is_list(conversations) -> length(conversations)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp get_message_queue_lengths do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} -> len
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp get_heap_sizes do
    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, :heap_size) do
        {:heap_size, size} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp count_redis_connections do
    # Approximation basée sur les pools Redis configurés
    3  # main_pool, session_pool, queue_pool
  end

  defp get_redis_memory_usage do
    case WhisprMessaging.Cache.RedisConnection.command("INFO", ["memory"]) do
      {:ok, info} -> parse_redis_memory(info)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp parse_redis_memory(info) when is_binary(info) do
    # Parser l'output de INFO memory pour extraire used_memory
    info
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":") do
        ["used_memory", value] -> String.to_integer(value)
        _ -> nil
      end
    end)
  end

  defp parse_redis_memory(_), do: 0

  defp count_active_users_since(_since_datetime) do
    # Compter les utilisateurs actifs via les présences
    WhisprMessagingWeb.Presence.list("users")
    |> Map.keys()
    |> length()
  end

  defp get_p95_delivery_time do
    # Cette métrique nécessiterait un système de tracking plus avancé
    # Pour l'instant, on retourne une valeur par défaut
    100  # 100ms
  end

  defp safe_call(module, fun, args, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
      try do
        apply(module, fun, args)
      rescue
        _ -> default
      end
    else
      default
    end
  end

  defp schedule_metrics_collection do
    # Collecte des métriques toutes les 5 minutes
    Process.send_after(self(), :collect_metrics, 300_000)
  end
end
