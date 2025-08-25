defmodule WhisprMessaging.Presence.Supervisor do
  @moduledoc """
  Superviseur pour la gestion des informations de présence utilisateur selon system_design.md
  Gère le tracking des utilisateurs en ligne, la synchronisation multi-appareils,
  et les indicateurs de présence.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Registry pour la localisation des processus de présence
      {Registry, keys: :unique, name: WhisprMessaging.Presence.Registry},
      
      # Worker de synchronisation de présence
      WhisprMessaging.Presence.SyncWorker,
      
      # Worker de nettoyage des présences expirées
      WhisprMessaging.Presence.CleanupWorker,
      
      # Superviseur dynamique pour les processus de présence par utilisateur
      {DynamicSupervisor, strategy: :one_for_one, name: WhisprMessaging.Presence.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
