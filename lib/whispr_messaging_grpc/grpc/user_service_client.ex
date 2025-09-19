defmodule WhisprMessaging.Grpc.UserServiceClient do
  @moduledoc """
  Client gRPC pour communiquer avec user-service
  selon la documentation system_design.md
  """
  
  require Logger

  @service_name "user-service"
  @default_timeout 5_000

  ## Fonctions publiques d'interface

  @doc """
  Valider les permissions d'envoi de message
  """
  def validate_message_permissions(sender_id, conversation_id, participant_ids, message_type \\ "text") do
    request = %{
      sender_id: sender_id,
      conversation_id: conversation_id,
      participant_ids: participant_ids,
      message_type: message_type
    }
    
    Logger.debug("Validating message permissions", %{
      sender_id: sender_id,
      conversation_id: conversation_id,
      participant_count: length(participant_ids)
    })
    
    case make_grpc_call(:validate_message_permissions, request) do
      {:ok, response} ->
        if response.permission_granted do
          {:ok, %{
            allowed_recipients: response.allowed_recipients,
            blocked_recipients: response.blocked_recipients
          }}
        else
          {:error, response.reason}
        end
        
      {:error, reason} ->
        Logger.error("Failed to validate message permissions", %{
          error: reason,
          sender_id: sender_id,
          conversation_id: conversation_id
        })
        {:error, reason}
    end
  end

  @doc """
  Vérifier si un utilisateur peut accéder à une conversation
  """
  def validate_conversation_access(user_id, conversation_id, action \\ "read") do
    request = %{
      user_id: user_id,
      conversation_id: conversation_id,
      action: action
    }
    
    Logger.debug("Validating conversation access", %{
      user_id: user_id,
      conversation_id: conversation_id,
      action: action
    })
    
    case make_grpc_call(:validate_conversation_access, request) do
      {:ok, response} ->
        if response.access_granted do
          {:ok, %{
            permissions: response.permissions
          }}
        else
          {:error, response.reason}
        end
        
      {:error, reason} ->
        Logger.error("Failed to validate conversation access", %{
          error: reason,
          user_id: user_id,
          conversation_id: conversation_id
        })
        {:error, reason}
    end
  end

  @doc """
  Obtenir la liste des participants actifs d'une conversation
  """
  def get_conversation_participants(conversation_id, include_inactive \\ false) do
    request = %{
      conversation_id: conversation_id,
      include_inactive: include_inactive
    }
    
    Logger.debug("Getting conversation participants", %{
      conversation_id: conversation_id,
      include_inactive: include_inactive
    })
    
    case make_grpc_call(:get_conversation_participants, request) do
      {:ok, response} ->
        participants = Enum.map(response.participants, fn p ->
          %{
            user_id: p.user_id,
            role: p.role,
            is_active: p.is_active,
            joined_at: p.joined_at,
            last_seen: p.last_seen
          }
        end)
        
        {:ok, %{
          participants: participants,
          total_count: response.total_count
        }}
        
      {:error, reason} ->
        Logger.error("Failed to get conversation participants", %{
          error: reason,
          conversation_id: conversation_id
        })
        {:error, reason}
    end
  end

  @doc """
  Vérifier les blocages entre utilisateurs
  """
  def check_user_blocks(user_id, target_user_ids) when is_list(target_user_ids) do
    request = %{
      user_id: user_id,
      target_user_ids: target_user_ids
    }
    
    Logger.debug("Checking user blocks", %{
      user_id: user_id,
      target_count: length(target_user_ids)
    })
    
    case make_grpc_call(:check_user_blocks, request) do
      {:ok, response} ->
        {:ok, %{
          is_blocked: response.is_blocked,
          has_blocked: response.has_blocked
        }}
        
      {:error, reason} ->
        Logger.error("Failed to check user blocks", %{
          error: reason,
          user_id: user_id
        })
        {:error, reason}
    end
  end

  def check_user_blocks(user_id, target_user_id) when is_binary(target_user_id) do
    check_user_blocks(user_id, [target_user_id])
  end

  ## Fonctions privées

  defp make_grpc_call(method, request, timeout \\ @default_timeout) do
    config = get_service_config()
    
    try do
      # Utilisation de grpcbox pour l'appel gRPC réel
      channel_opts = build_channel_opts(config, timeout)
      
      case :grpcbox_client.unary(
        build_channel_name(config),
        "/user.UserService/#{Macro.camelize(to_string(method))}",
        request,
        channel_opts
      ) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} ->
          Logger.error("gRPC call failed", %{
            method: method,
            reason: reason,
            service: @service_name
          })
          
          # Fallback vers simulation en mode développement
          if Application.get_env(:whispr_messaging, :environment) == :dev do
            Logger.warning("Falling back to simulation for development")
            simulate_grpc_call(method, request)
          else
            {:error, reason}
          end
      end
    rescue
      error ->
        Logger.error("gRPC call exception", %{
          method: method,
          error: inspect(error),
          service: @service_name
        })
        
        # Fallback vers simulation en mode développement
        if Application.get_env(:whispr_messaging, :environment) == :dev do
          Logger.warning("Exception occurred, falling back to simulation")
          simulate_grpc_call(method, request)
        else
          {:error, :grpc_exception}
        end
    end
  end

  defp get_service_config do
    %{
      host: Application.get_env(:whispr_messaging, :user_service_host, "user-service"),
      port: Application.get_env(:whispr_messaging, :user_service_port, 50052),
      timeout: Application.get_env(:whispr_messaging, :grpc_timeout, @default_timeout),
      ssl: Application.get_env(:whispr_messaging, :grpc_ssl, false)
    }
  end

  defp build_channel_name(config) do
    :"#{config.host}_#{config.port}_channel"
  end

  defp build_channel_opts(config, timeout) do
    base_opts = [
      timeout: timeout,
      deadline: :timer.seconds(timeout / 1000)
    ]
    
    if config.ssl do
      base_opts ++ [transport: :ssl]
    else
      base_opts
    end
  end

  @doc """
  Initialise la connexion gRPC avec le user-service
  """
  def start_connection do
    config = get_service_config()
    channel_name = build_channel_name(config)
    
    channel_opts = [
      {config.host, config.port, []}
    ]
    
    case :grpcbox_channel.start_link(channel_name, channel_opts) do
      {:ok, _pid} ->
        Logger.info("gRPC connection to user-service established", %{
          host: config.host,
          port: config.port
        })
        :ok
      {:error, reason} ->
        Logger.error("Failed to establish gRPC connection to user-service", %{
          reason: reason,
          host: config.host,
          port: config.port
        })
        {:error, reason}
    end
  end

  # Simulation temporaire des appels gRPC pour les tests
  defp simulate_grpc_call(:validate_message_permissions, request) do
    # Simulation basique : autoriser si l'utilisateur n'est pas dans sa propre liste de participants
    if request.sender_id in request.participant_ids do
      {:ok, %{
        permission_granted: true,
        reason: "authorized",
        allowed_recipients: request.participant_ids -- [request.sender_id],
        blocked_recipients: []
      }}
    else
      {:ok, %{
        permission_granted: false,
        reason: "not_a_member",
        allowed_recipients: [],
        blocked_recipients: request.participant_ids
      }}
    end
  end

  defp simulate_grpc_call(:validate_conversation_access, _request) do
    # Simulation basique : autoriser tous les accès pour les tests
    {:ok, %{
      access_granted: true,
      reason: "authorized",
      permissions: %{
        "read" => true,
        "write" => true,
        "admin" => false
      }
    }}
  end

  defp simulate_grpc_call(:get_conversation_participants, _request) do
    # Simulation basique avec des participants factices
    {:ok, %{
      participants: [
        %{
          user_id: "00000000-0000-0000-0000-000000000001",
          role: "admin",
          is_active: true,
          joined_at: DateTime.utc_now() |> DateTime.to_unix(),
          last_seen: DateTime.utc_now() |> DateTime.to_unix()
        }
      ],
      total_count: 1
    }}
  end

  defp simulate_grpc_call(:check_user_blocks, request) do
    # Simulation basique : aucun blocage
    is_blocked = request.target_user_ids |> Enum.map(fn id -> {id, false} end) |> Enum.into(%{})
    has_blocked = request.target_user_ids |> Enum.map(fn id -> {id, false} end) |> Enum.into(%{})
    
    {:ok, %{
      is_blocked: is_blocked,
      has_blocked: has_blocked
    }}
  end

  defp simulate_grpc_call(method, _request) do
    Logger.warning("Unimplemented gRPC method simulation", %{method: method})
    {:error, :method_not_implemented}
  end
end
