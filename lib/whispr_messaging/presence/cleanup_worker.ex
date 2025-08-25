defmodule WhisprMessaging.Presence.CleanupWorker do
  @moduledoc """
  Worker de nettoyage des présences expirées selon system_design.md
  Nettoie les données de présence obsolètes et maintient la cohérence.
  """
  use GenServer
  
  require Logger
  
  alias WhisprMessaging.Cache.RedisConnection

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Démarrer le nettoyage périodique
    schedule_cleanup()
    
    state = %{
      last_cleanup: DateTime.utc_now(),
      cleaned_presences: 0
    }
    
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleaned_count = perform_presence_cleanup()
    
    schedule_cleanup()
    
    new_state = %{state | 
      last_cleanup: DateTime.utc_now(),
      cleaned_presences: state.cleaned_presences + cleaned_count
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_cleanup_stats, _from, state) do
    stats = %{
      last_cleanup: state.last_cleanup,
      total_cleaned: state.cleaned_presences
    }
    
    {:reply, stats, state}
  end

  ## Private Functions

  defp perform_presence_cleanup do
    try do
      # Nettoyer les présences expirées dans Redis
      expired_keys = find_expired_presence_keys()
      
      Enum.each(expired_keys, fn key ->
        RedisConnection.command("DEL", [key])
      end)
      
      # Nettoyer les présences Phoenix orphelines
      cleanup_phoenix_presences()
      
      length(expired_keys)
    rescue
      error ->
        Logger.warning("Presence cleanup failed: #{inspect(error)}")
        0
    end
  end

  defp find_expired_presence_keys do
    # Chercher les clés de présence expirées
    case RedisConnection.command("SCAN", ["0", "MATCH", "presence:user:*", "COUNT", "100"]) do
      {:ok, [_cursor, keys]} ->
        keys
        |> Enum.filter(&is_presence_expired?/1)
        
      _ ->
        []
    end
  end

  defp is_presence_expired?(key) do
    case RedisConnection.command("HGET", [key, "last_seen"]) do
      {:ok, nil} -> true
      {:ok, last_seen_str} ->
        case DateTime.from_iso8601(last_seen_str) do
          {:ok, last_seen, _} ->
            DateTime.diff(DateTime.utc_now(), last_seen, :second) > 300  # 5 minutes
          _ ->
            true  # Format invalide, considéré comme expiré
        end
      _ ->
        true
    end
  end

  defp cleanup_phoenix_presences do
    # Nettoyer les présences Phoenix pour les utilisateurs non connectés
    WhisprMessagingWeb.Presence.list("users")
    |> Enum.each(fn {user_id, %{metas: metas}} ->
      # Vérifier si les connexions sont encore valides
      valid_metas = Enum.filter(metas, &is_connection_valid?/1)
      
      if length(valid_metas) != length(metas) do
        # Mettre à jour avec seulement les connexions valides
        if length(valid_metas) == 0 do
          WhisprMessagingWeb.Presence.untrack(self(), "users", user_id)
        else
          # Re-track avec les metas valides
          Enum.each(valid_metas, fn meta ->
            WhisprMessagingWeb.Presence.track(self(), "users", user_id, meta)
          end)
        end
      end
    end)
  end

  defp is_connection_valid?(meta) do
    # Vérifier si le processus de connexion est encore vivant
    case Map.get(meta, :channel_pid) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp schedule_cleanup do
    # Nettoyage toutes les 2 minutes
    Process.send_after(self(), :cleanup_expired, 120_000)
  end
end
