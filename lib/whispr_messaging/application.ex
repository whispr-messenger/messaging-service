defmodule WhisprMessaging.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Base infrastructure
      WhisprMessagingWeb.Telemetry,
      WhisprMessaging.Repo,
      {DNSCluster, query: Application.get_env(:whispr_messaging, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WhisprMessaging.PubSub},
      
      # Cache Redis avec pools multiples (temporairement désactivé pour stabilité)
      # WhisprMessaging.Cache.Supervisor,
      
      # Architecture OTP selon system_design.md
      # Registry pour la localisation des processus de conversation
      {Registry, keys: :unique, name: WhisprMessaging.Conversations.Registry},
      
      # ConversationSupervisor : Supervision dynamique des processus de conversation
      WhisprMessaging.Conversations.Supervisor,
      
      # PresenceSupervisor : Gestion des informations de présence utilisateur
      WhisprMessaging.Presence.Supervisor,
      
      # WorkersSupervisor : Gestion des tâches de fond (temporairement désactivé pour stabilité)
      # WhisprMessaging.WorkersSupervisor,
      
      # Modules Presence Phoenix pour tracking des utilisateurs
      WhisprMessagingWeb.Presence,
      WhisprMessagingWeb.ConversationPresence,
      
      # gRPC Server Supervisor : Supervision du serveur gRPC (temporairement désactivé - API grpcbox en cours de correction)
      # WhisprMessaging.Grpc.Supervisor,
      
      # Phoenix Endpoint - toujours en dernier
      WhisprMessagingWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WhisprMessaging.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisprMessagingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
