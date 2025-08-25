defmodule WhisprMessaging.WorkersSupervisor do
  @moduledoc """
  Superviseur pour la gestion des tâches de fond selon system_design.md
  Supervise les workers de maintenance, nettoyage, métriques et autres tâches asynchrones.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Workers de maintenance et nettoyage
      
      # Worker de nettoyage des messages
      WhisprMessaging.WorkersMessageCleanup,
      
      # Worker de rapports de métriques
      WhisprMessaging.WorkersMetricsReporter,
      
      # Worker de maintenance des index de recherche
      WhisprMessaging.WorkersSearchIndexMaintainer,
      
      # Worker de traitement des messages programmés
      WhisprMessaging.WorkersScheduledMessageProcessor,
      
      # Worker de synchronisation avec les services externes
      WhisprMessaging.WorkersExternalSyncWorker
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
