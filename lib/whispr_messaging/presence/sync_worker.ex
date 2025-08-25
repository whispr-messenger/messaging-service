defmodule WhisprMessaging.Presence.SyncWorker do
  @moduledoc """
  Worker de synchronisation de présence selon system_design.md
  Synchronise les informations de présence entre les nœuds du cluster
  et maintient la cohérence des données de présence.
  """
  use GenServer
  
  require Logger
  
  alias WhisprMessaging.Cache.RedisConnection

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Démarrer la synchronisation périodique
    schedule_sync()
    
    state = %{
      last_sync: DateTime.utc_now(),
      sync_errors: 0
    }
    
    {:ok, state}
  end

  @impl true
  def handle_info(:sync_presence, state) do
    case perform_presence_sync() do
      :ok ->
        schedule_sync()
        new_state = %{state | 
          last_sync: DateTime.utc_now(),
          sync_errors: 0
        }
        {:noreply, new_state}
        
      {:error, reason} ->
        Logger.warning("Presence sync failed: #{inspect(reason)}")
        schedule_sync()
        new_state = %{state | sync_errors: state.sync_errors + 1}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:get_sync_status, _from, state) do
    status = %{
      last_sync: state.last_sync,
      sync_errors: state.sync_errors,
      node: Node.self()
    }
    
    {:reply, status, state}
  end

  ## Private Functions

  defp perform_presence_sync do
    try do
      # Synchroniser les présences locales avec Redis
      local_presences = collect_local_presences()
      
      # Publier les présences locales
      Enum.each(local_presences, fn {user_id, presence_data} ->
        RedisConnection.command("HSET", [
          "presence:user:#{user_id}",
          "node", Node.self(),
          "last_seen", DateTime.utc_now() |> DateTime.to_iso8601(),
          "connections", presence_data.connections,
          "status", presence_data.status
        ])
        
        # TTL de 2 minutes
        RedisConnection.command("EXPIRE", ["presence:user:#{user_id}", 120])
      end)
      
      :ok
    rescue
      error ->
        {:error, error}
    end
  end

  defp collect_local_presences do
    # Collecter les présences depuis les processus Phoenix.Presence locaux
    WhisprMessagingWeb.Presence.list("users")
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      presence_data = %{
        connections: length(metas),
        status: get_user_status(metas),
        last_activity: get_last_activity(metas)
      }
      
      {user_id, presence_data}
    end)
    |> Enum.into(%{})
  end

  defp get_user_status(metas) do
    # Détermine le statut basé sur les métadonnées
    if Enum.any?(metas, & &1.active) do
      "online"
    else
      "away"
    end
  end

  defp get_last_activity(metas) do
    metas
    |> Enum.map(& &1.last_activity)
    |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
  end

  defp schedule_sync do
    # Synchronisation toutes les 30 secondes
    Process.send_after(self(), :sync_presence, 30_000)
  end
end
