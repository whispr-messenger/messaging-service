defmodule WhisprMessaging.Grpc.Supervisor do
  @moduledoc """
  Superviseur pour les services gRPC du messaging-service
  """
  
  use Supervisor
  
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("Starting gRPC Supervisor for messaging-service")
    
    children = [
      # Configuration gRPC correcte selon grpcbox documentation
      %{
        id: :grpcbox_server,
        start: {:grpcbox, :start_link, [
          get_listen_opts(),
          get_grpc_services()
        ]},
        type: :supervisor,
        restart: :permanent,
        shutdown: :infinity
      }
    ]

    opts = [strategy: :one_for_one, name: WhisprMessaging.Grpc.Supervisor]
    Supervisor.init(children, opts)
  end

  defp get_listen_opts do
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

  defp get_grpc_services do
    # Configuration des services gRPC selon GRPC_GUIDE.md
    # MessagingService avec 4 méthodes : NotifyConversationEvent, LinkMediaToMessage, GetConversationStats, NotifyGroupCreation
    %{
      protos: [WhisprMessaging.Grpc.MessagingService],
      services: %{
        ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
      }
    }
  end
end
