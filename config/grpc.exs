# Configuration gRPC pour le messaging-service

import Config

# Configuration grpcbox
config :grpcbox,
  # Services que nous exposons
  servers: [
    %{
      grpc_opts: %{
        service_protos: [WhisprMessaging.Grpc.MessagingService],
        services: %{
          ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
        }
      }
    }
  ],
  # Configuration des clients (services que nous consommons)
  client_opts: %{
    # Retry par défaut
    max_retries: 3,
    retry_timeout: 1000,
    # Pool de connexions
    pool_size: 10,
    pool_max_overflow: 20
  }

# Configuration spécifique par environnement
case Mix.env() do
  :dev ->
    config :grpcbox,
      servers: [
        %{
          grpc_opts: %{
            service_protos: [WhisprMessaging.Grpc.MessagingService],
            services: %{
              ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
            },
            # Port de développement
            listen_opts: %{
              port: 9090,
              ip: {127, 0, 0, 1}
            }
          }
        }
      ]

  :test ->
    config :grpcbox,
      servers: [
        %{
          grpc_opts: %{
            service_protos: [WhisprMessaging.Grpc.MessagingService],
            services: %{
              ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
            },
            # Port de test
            listen_opts: %{
              port: 9091,
              ip: {127, 0, 0, 1}
            }
          }
        }
      ]

  :prod ->
    config :grpcbox,
      servers: [
        %{
          grpc_opts: %{
            service_protos: [WhisprMessaging.Grpc.MessagingService],
            services: %{
              ~c"messaging.MessagingService" => WhisprMessaging.Grpc.MessagingServiceImpl
            },
            # Configuration production (sera définie via variables d'environnement)
            listen_opts: %{
              port: String.to_integer(System.get_env("GRPC_PORT") || "9090"),
              ip: {0, 0, 0, 0} # Écouter sur toutes les interfaces
            }
          }
        }
      ]
end
