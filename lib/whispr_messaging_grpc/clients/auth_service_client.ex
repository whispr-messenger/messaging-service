defmodule WhisprMessaging.Grpc.AuthServiceClient do
  @moduledoc """
  Client gRPC pour communiquer avec auth-service
  Gère la validation des tokens, la récupération des clés publiques et les opérations d'authentification
  """
  
  require Logger
  
  @service_name "auth-service"
  @default_timeout 5_000
  @max_retries 3
  @retry_delay 1_000

  # Configuration du service
  defp get_service_config do
    %{
      host: Application.get_env(:whispr_messaging, :auth_service_host, "auth-service"),
      port: Application.get_env(:whispr_messaging, :auth_service_port, 50051),
      timeout: Application.get_env(:whispr_messaging, :grpc_timeout, @default_timeout),
      ssl: Application.get_env(:whispr_messaging, :grpc_ssl, false)
    }
  end

  @doc """
  Valide un token JWT auprès de l'auth-service
  """
  def validate_token(token) when is_binary(token) do
    request = %{
      token: token,
      service_name: "messaging-service",
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    case make_grpc_call(:validate_token, request) do
      {:ok, response} ->
        if response.valid do
          {:ok, %{
            user_id: response.user_id,
            device_id: response.device_id,
            permissions: response.permissions || [],
            expires_at: response.expires_at,
            claims: response.claims || %{}
          }}
        else
          {:error, response.error_reason || :invalid_token}
        end
      {:error, reason} ->
        Logger.error("Token validation failed", %{reason: reason, token_prefix: String.slice(token, 0, 10)})
        {:error, reason}
    end
  end

  @doc """
  Récupère les clés publiques JWKS depuis l'auth-service
  """
  def get_jwks_keys do
    request = %{
      service_name: "messaging-service",
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    case make_grpc_call(:get_jwks_keys, request) do
      {:ok, response} ->
        {:ok, %{
          keys: response.keys,
          cache_ttl: response.cache_ttl || 3600
        }}
      {:error, reason} ->
        Logger.error("Failed to fetch JWKS keys", %{reason: reason})
        {:error, reason}
    end
  end

  @doc """
  Vérifie si un token est révoqué
  """
  def check_token_revocation(token_id) when is_binary(token_id) do
    request = %{
      token_id: token_id,
      service_name: "messaging-service"
    }
    
    case make_grpc_call(:check_token_revocation, request) do
      {:ok, response} ->
        {:ok, response.is_revoked}
      {:error, reason} ->
        Logger.error("Token revocation check failed", %{reason: reason, token_id: token_id})
        {:error, reason}
    end
  end

  @doc """
  Révoque un token spécifique
  """
  def revoke_token(token_id, reason \\ "security_incident") do
    request = %{
      token_id: token_id,
      reason: reason,
      service_name: "messaging-service",
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    case make_grpc_call(:revoke_token, request) do
      {:ok, response} ->
        if response.success do
          :ok
        else
          {:error, response.error_message}
        end
      {:error, reason} ->
        Logger.error("Token revocation failed", %{reason: reason, token_id: token_id})
        {:error, reason}
    end
  end

  @doc """
  Révoque tous les tokens d'un utilisateur
  """
  def revoke_user_tokens(user_id, reason \\ "security_incident") do
    request = %{
      user_id: user_id,
      reason: reason,
      service_name: "messaging-service",
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    case make_grpc_call(:revoke_user_tokens, request) do
      {:ok, response} ->
        {:ok, %{
          revoked_count: response.revoked_count,
          failed_tokens: response.failed_tokens || []
        }}
      {:error, reason} ->
        Logger.error("User tokens revocation failed", %{reason: reason, user_id: user_id})
        {:error, reason}
    end
  end

  @doc """
  Vérifie les permissions d'un utilisateur pour une action spécifique
  """
  def check_permissions(user_id, resource, action) do
    request = %{
      user_id: user_id,
      resource: resource,
      action: action,
      service_name: "messaging-service"
    }
    
    case make_grpc_call(:check_permissions, request) do
      {:ok, response} ->
        {:ok, response.allowed}
      {:error, reason} ->
        Logger.error("Permission check failed", %{
          reason: reason, 
          user_id: user_id, 
          resource: resource, 
          action: action
        })
        {:error, reason}
    end
  end

  # Fonctions privées pour la communication gRPC

  defp make_grpc_call(method, request, retry_count \\ 0) do
    config = get_service_config()
    
    try do
      # Utilisation de grpcbox pour l'appel gRPC
      channel_opts = build_channel_opts(config)
      
      case :grpcbox_client.unary(
        build_channel_name(config),
        "/auth.AuthService/#{Macro.camelize(to_string(method))}",
        request,
        channel_opts
      ) do
        {:ok, response} ->
          {:ok, response}
        {:error, reason} when retry_count < @max_retries ->
          Logger.warning("gRPC call failed, retrying", %{
            method: method,
            reason: reason,
            retry_count: retry_count + 1
          })
          
          # Attendre avant de réessayer
          :timer.sleep(@retry_delay * (retry_count + 1))
          make_grpc_call(method, request, retry_count + 1)
        {:error, reason} ->
          Logger.error("gRPC call failed after retries", %{
            method: method,
            reason: reason,
            max_retries: @max_retries
          })
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("gRPC call exception", %{
          method: method,
          error: inspect(error),
          retry_count: retry_count
        })
        
        if retry_count < @max_retries do
          :timer.sleep(@retry_delay * (retry_count + 1))
          make_grpc_call(method, request, retry_count + 1)
        else
          {:error, :grpc_exception}
        end
    end
  end

  defp build_channel_name(config) do
    :"#{config.host}_#{config.port}_channel"
  end

  defp build_channel_opts(config) do
    base_opts = [
      timeout: config.timeout,
      deadline: :timer.seconds(config.timeout / 1000)
    ]
    
    if config.ssl do
      base_opts ++ [transport: :ssl]
    else
      base_opts
    end
  end

  @doc """
  Initialise la connexion gRPC avec l'auth-service
  """
  def start_connection do
    config = get_service_config()
    channel_name = build_channel_name(config)
    
    channel_opts = [
      {config.host, config.port, []}
    ]
    
    case :grpcbox_channel.start_link(channel_name, channel_opts) do
      {:ok, _pid} ->
        Logger.info("gRPC connection to auth-service established", %{
          host: config.host,
          port: config.port
        })
        :ok
      {:error, reason} ->
        Logger.error("Failed to establish gRPC connection to auth-service", %{
          reason: reason,
          host: config.host,
          port: config.port
        })
        {:error, reason}
    end
  end

  @doc """
  Ferme la connexion gRPC avec l'auth-service
  """
  def stop_connection do
    config = get_service_config()
    channel_name = build_channel_name(config)
    
    case :grpcbox_channel.stop(channel_name) do
      :ok ->
        Logger.info("gRPC connection to auth-service closed")
        :ok
      {:error, reason} ->
        Logger.warning("Failed to close gRPC connection to auth-service", %{reason: reason})
        {:error, reason}
    end
  end

  @doc """
  Vérifie la santé de la connexion avec l'auth-service
  """
  def health_check do
    request = %{
      service: @service_name,
      timestamp: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    case make_grpc_call(:health_check, request) do
      {:ok, response} ->
        {:ok, %{
          status: response.status,
          version: response.version,
          uptime: response.uptime
        }}
      {:error, reason} ->
        {:error, reason}
    end
  end
end