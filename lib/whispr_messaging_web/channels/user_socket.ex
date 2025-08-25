defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  Socket utilisateur pour l'authentification et la gestion des connexions WebSocket
  selon la documentation 9_websocket_rtc.md
  """
  use Phoenix.Socket

  # Channels disponibles
  channel "user:*", WhisprMessagingWeb.UserChannel
  channel "conversation:*", WhisprMessagingWeb.ConversationChannel

  # Transport
  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    remote_ip = get_ip_address(connect_info)
    
    # Vérifications de sécurité préalables
    with :ok <- WhisprMessaging.Security.Middleware.check_connection_limits(remote_ip),
         {:ok, user_data} <- authenticate_user(token, connect_info),
         :ok <- WhisprMessaging.Security.Middleware.check_user_blocks(user_data.user_id) do
      
      # Enregistrer la connexion pour tracking
      connection_id = generate_connection_id()
      WhisprMessaging.Security.Middleware.register_connection(
        remote_ip, 
        connection_id, 
        user_data.user_id
      )
      
      socket = 
        socket
        |> assign(:user_id, user_data.user_id)
        |> assign(:device_id, user_data.device_id)
        |> assign(:connection_id, connection_id)
        |> assign(:trust_level, user_data.trust_level)
        |> assign(:connected_at, DateTime.utc_now())
        |> assign(:ip_address, remote_ip)
        |> assign(:user_agent, get_user_agent(connect_info))

      # Stocker la session dans Redis Cache
      session_data = %{
        user_id: user_data.user_id,
        device_id: user_data.device_id,
        connection_id: connection_id,
        ip_address: remote_ip,
        user_agent: get_user_agent(connect_info),
        trust_level: user_data.trust_level
      }
      
      session_id = generate_session_id(user_data.user_id, user_data.device_id)
      WhisprMessaging.Cache.SessionCache.store_session(session_id, session_data)
      
      socket = assign(socket, :session_id, session_id)

      # Log de la connexion sécurisée
      log_secure_connection(user_data, connect_info)
      
      {:ok, socket}
    else
      {:error, reason} ->
        # Log de l'échec d'authentification avec détails de sécurité
        log_auth_failure(token, reason, connect_info)
        :error
    end
  end

  # Connexion sans token (rejetée)
  @impl true
  def connect(_params, _socket, _connect_info) do
    :error
  end

  # Identification du socket pour le PubSub
  @impl true
  def id(socket) do
    user_id = socket.assigns.user_id
    device_id = socket.assigns.device_id
    "user_socket:#{user_id}:#{device_id}"
  end

  # Nettoyage lors de la déconnexion
  # Note: Phoenix.Socket définit déjà terminate/2 par défaut
  # Le nettoyage sera géré par les channels individuels

  ## Fonctions privées

  defp authenticate_user(token, connect_info) do
    # Validation JWT complète avec sécurité renforcée
    case WhisprMessaging.Security.JwtValidator.quick_validate_token(token) do
      {:ok, user_data} ->
        # Vérifications additionnelles de sécurité
        with :ok <- verify_device_consistency(user_data, connect_info),
             :ok <- check_user_active_status(user_data.user_id) do
          {:ok, user_data}
        else
          {:error, reason} -> {:error, reason}
        end
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_device_consistency(user_data, _connect_info) do
    # Vérifier la cohérence des informations de device
    # TODO: Implémenter vérification avec user-service si nécessaire
    # Pour l'instant, accepter tous les devices valides
    if user_data.device_id && String.length(user_data.device_id) > 0 do
      :ok
    else
      {:error, :invalid_device_info}
    end
  end

  defp check_user_active_status(user_id) do
    # TODO: Vérifier avec user-service que l'utilisateur est actif
    # Pour l'instant, accepter tous les UUIDs valides
    case Ecto.UUID.cast(user_id) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_user_id}
    end
  end

  # defp generate_device_id do
  #   # Générer un ID unique pour l'appareil si non fourni
  #   UUID.uuid4()
  # end

  defp generate_session_id(user_id, device_id) do
    # Générer un ID unique pour la session WebSocket
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "#{user_id}_#{device_id}_#{timestamp}_#{:rand.uniform(10000)}"
  end

  defp generate_connection_id do
    # Générer un ID unique pour tracking de connexion sécurisé
    "conn_" <> UUID.uuid4()
  end

  defp get_ip_address(connect_info) do
    case connect_info[:peer_data] do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _ -> "unknown"
    end
  end

  defp get_user_agent(connect_info) do
    case connect_info[:x_headers] do
      headers when is_list(headers) ->
        Enum.find_value(headers, "unknown", fn
          {"user-agent", value} -> value
          _ -> nil
        end)
      _ -> "unknown"
    end
  end

  defp log_secure_connection(user_data, connect_info) do
    require Logger
    
    ip = get_ip_address(connect_info)
    user_agent = get_user_agent(connect_info)
    
    Logger.info("Secure WebSocket connection established", %{
      user_id: user_data.user_id,
      device_id: user_data.device_id,
      trust_level: user_data.trust_level,
      ip_address: ip,
      user_agent: user_agent,
      session_id: user_data.session_id,
      timestamp: DateTime.utc_now()
    })
    
    # Enregistrer l'activité pour détection de patterns
    WhisprMessaging.Security.Middleware.detect_suspicious_activity(
      user_data.user_id, 
      "websocket_connection",
      %{ip_address: ip, user_agent: user_agent}
    )
  end

  defp log_auth_failure(token, reason, connect_info) do
    require Logger
    
    ip = get_ip_address(connect_info)
    user_agent = get_user_agent(connect_info)
    
    Logger.warning("Secure WebSocket authentication failed", %{
      reason: reason,
      token_prefix: String.slice(token || "", 0, 10),
      ip_address: ip,
      user_agent: user_agent,
      timestamp: DateTime.utc_now()
    })
    
    # Enregistrer la tentative échouée pour détection d'intrusion
    # TODO: Implémenter counter de tentatives échouées par IP
    case reason do
      :token_expired -> :ok # Erreur normale
      :invalid_token -> 
        # Tentative d'intrusion potentielle
        WhisprMessaging.Security.Middleware.detect_suspicious_activity(
          "unknown", 
          "auth_failure",
          %{ip_address: ip, reason: reason}
        )
      _ -> :ok
    end
  end
end
