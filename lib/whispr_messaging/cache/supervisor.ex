defmodule WhisprMessaging.Cache.Supervisor do
  @moduledoc """
  Superviseur pour les services de cache Redis
  """
  
  use Supervisor
  
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("Starting Cache Supervisor with Redis pools")
    
    children = [
      # Connexions Redis avec pools multiples
      WhisprMessaging.Cache.RedisConnection,
      
      # Workers de nettoyage et maintenance des caches (temporairement désactivés pour stabilité)
      # {WhisprMessaging.Cache.CleanupWorker, []},
      
      # Worker de métriques cache (temporairement désactivé pour stabilité)
      # {WhisprMessaging.Cache.MetricsWorker, []}
    ]

    opts = [strategy: :one_for_one, name: WhisprMessaging.Cache.CacheSupervisor]
    Supervisor.init(children, opts)
  end
end
