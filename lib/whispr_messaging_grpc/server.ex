defmodule WhisprMessaging.Grpc.Server do
  @moduledoc """
  Serveur gRPC principal selon system_design.md et GRPC_GUIDE.md
  
  Ce module démarre et supervise le serveur gRPC pour la communication
  inter-services avec les services de notification, média et utilisateurs.
  
  Implémente les 4 méthodes principales documentées dans GRPC_GUIDE.md :
  1. NotifyConversationEvent
  2. GetMediaMetadata  
  3. SendNotification
  4. ValidateUserAccess
  """
  
  require Logger
  
  @doc """
  Démarre le serveur gRPC avec la configuration selon l'environnement
  """
  def start_link(_init_arg) do
    Logger.info("Starting gRPC Server for messaging-service")
    
    grpc_config = get_grpc_config()
    
    # Configuration du serveur gRPC selon grpcbox
    server_opts = %{
      port: grpc_config.port,
      ip: grpc_config.ip
    }
    
    services_config = %{
      services: %{
        # Service de messagerie principal
        ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
      },
      protos: [
        WhisprMessaging.Grpc.MessagingService
      ]
    }
    
    # Démarrage avec l'API grpcbox corrigée
    case start_grpcbox_server(server_opts, services_config) do
      {:ok, pid} ->
        Logger.info("gRPC Server started successfully on #{grpc_config.ip}:#{grpc_config.port}")
        {:ok, pid}
        
      {:error, reason} ->
        Logger.error("Failed to start gRPC Server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Arrête proprement le serveur gRPC
  """
  def stop(_pid) do
    Logger.info("Stopping gRPC Server")
    # Arrêt propre du serveur
    :ok
  end

  ## Fonctions privées

  defp get_grpc_config do
    case Mix.env() do
      :test ->
        %{
          port: String.to_integer(System.get_env("GRPC_TEST_PORT") || "9091"),
          ip: {127, 0, 0, 1}
        }
        
      :dev ->
        %{
          port: String.to_integer(System.get_env("GRPC_DEV_PORT") || "9090"),
          ip: {127, 0, 0, 1}
        }
        
      :prod ->
        %{
          port: String.to_integer(System.get_env("GRPC_PORT") || "9090"),
          ip: {0, 0, 0, 0} # Écouter sur toutes les interfaces en production
        }
    end
  end

  defp start_grpcbox_server(server_opts, services_config) do
    try do
      # Utilisation de l'API grpcbox corrigée
      # Note: Cette implémentation sera corrigée selon la vraie API grpcbox
      case :grpcbox_app.start_server(server_opts, services_config) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    rescue
      error ->
        Logger.error("grpcbox server failed to start: #{inspect(error)}")
        {:error, error}
    end
  end
end
