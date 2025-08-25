defmodule WhisprMessaging.Security.Middleware do
  @moduledoc """
  Middleware de sécurité pour WebSockets et API REST
  selon les spécifications security_policy.md
  """
  
  alias WhisprMessaging.Security.{RateLimiter, JwtValidator}
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  # Limites par défaut
  @max_connections_per_ip 10
  @max_message_size 10_000 # bytes
  @suspicious_patterns_threshold 5

  @doc """
  Vérifier les limites de connexion par IP
  """
  def check_connection_limits(remote_ip) when is_tuple(remote_ip) do
    ip_string = remote_ip |> :inet.ntoa() |> to_string()
    check_connection_limits(ip_string)
  end
  
  def check_connection_limits(remote_ip) when is_binary(remote_ip) do
    case count_connections_for_ip(remote_ip) do
      {:ok, current_connections} ->
        if current_connections >= @max_connections_per_ip do
          Logger.warning("IP connection limit exceeded", %{
            ip: remote_ip,
            current_connections: current_connections,
            limit: @max_connections_per_ip
          })
          {:error, :too_many_connections}
        else
          :ok
        end
        
      {:error, reason} ->
        Logger.error("Failed to check IP connection limits", %{
          ip: remote_ip,
          error: reason
        })
        # Fail open en cas d'erreur Redis
        :ok
    end
  end

  @doc """
  Enregistrer une nouvelle connexion pour une IP
  """
  def register_connection(remote_ip, connection_id, user_id \\ nil) do
    ip_string = if is_tuple(remote_ip), do: :inet.ntoa(remote_ip) |> to_string(), else: remote_ip
    
    connection_data = %{
      connection_id: connection_id,
      user_id: user_id,
      connected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      ip: ip_string
    }
    
    # Enregistrer la connexion avec TTL de 1 heure
    connection_key = "connection:#{connection_id}"
    ip_connection_key = "ip_connections:#{ip_string}"
    
    commands = [
      ["SETEX", connection_key, 3600, Jason.encode!(connection_data)],
      ["SADD", ip_connection_key, connection_id],
      ["EXPIRE", ip_connection_key, 3600]
    ]
    
    case RedisConnection.pipeline(commands) do
      {:ok, _results} ->
        Logger.debug("Connection registered", %{
          ip: ip_string,
          connection_id: connection_id,
          user_id: user_id
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to register connection", %{
          ip: ip_string,
          connection_id: connection_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Désenregistrer une connexion
  """
  def unregister_connection(remote_ip, connection_id) do
    ip_string = if is_tuple(remote_ip), do: :inet.ntoa(remote_ip) |> to_string(), else: remote_ip
    
    connection_key = "connection:#{connection_id}"
    ip_connection_key = "ip_connections:#{ip_string}"
    
    commands = [
      ["DEL", connection_key],
      ["SREM", ip_connection_key, connection_id]
    ]
    
    case RedisConnection.pipeline(commands) do
      {:ok, _results} ->
        Logger.debug("Connection unregistered", %{
          ip: ip_string,
          connection_id: connection_id
        })
        :ok
        
      {:error, reason} ->
        Logger.error("Failed to unregister connection", %{
          ip: ip_string,
          connection_id: connection_id,
          error: reason
        })
        {:error, reason}
    end
  end

  @doc """
  Valider la taille d'un message
  """
  def validate_message_size(message) when is_binary(message) do
    message_size = byte_size(message)
    
    if message_size > @max_message_size do
      Logger.warning("Message size limit exceeded", %{
        size: message_size,
        limit: @max_message_size
      })
      {:error, :message_too_large}
    else
      :ok
    end
  end
  
  def validate_message_size(_message), do: {:error, :invalid_message_format}

  @doc """
  Validation complète d'une requête WebSocket
  """
  def validate_websocket_request(socket, message, context \\ %{}) do
    user_id = socket.assigns[:user_id]
    _remote_ip = get_remote_ip(socket)
    
    with :ok <- validate_message_size(message),
         :ok <- check_user_blocks(user_id),
         {:ok, _} <- RateLimiter.check_rate_limit(user_id, "message"),
         :ok <- validate_content_safety(message),
         :ok <- check_suspicious_patterns(user_id, context) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validation d'une requête API REST
  """
  def validate_api_request(conn, action_type \\ "api_call") do
    remote_ip = get_remote_ip_from_conn(conn)
    token = extract_token_from_conn(conn)
    
    with {:ok, user_data} <- JwtValidator.quick_validate_token(token),
         :ok <- check_user_blocks(user_data.user_id),
         {:ok, _} <- RateLimiter.check_rate_limit(user_data.user_id, action_type),
         {:ok, _} <- RateLimiter.check_ip_rate_limit(remote_ip, "api_call") do
      {:ok, user_data}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Détecter et traiter une activité suspecte
  """
  def detect_suspicious_activity(user_id, activity_type, metadata \\ %{}) do
    activity_data = Map.merge(%{
      user_id: user_id,
      activity_type: activity_type,
      timestamp: DateTime.utc_now() |> DateTime.to_unix(),
      metadata: metadata
    }, calculate_activity_metrics(user_id))
    
    RateLimiter.detect_suspicious_activity(user_id, activity_data)
  end

  @doc """
  Appliquer des mesures de sécurité d'urgence
  """
  def apply_emergency_measures(user_id, threat_level, reason) do
    case threat_level do
      :low ->
        # Limitation temporaire légère
        RateLimiter.apply_temporary_block(user_id, reason, 300) # 5 minutes
        
      :medium ->
        # Blocage temporaire plus sévère + notification
        RateLimiter.apply_temporary_block(user_id, reason, 1800) # 30 minutes
        notify_security_incident(user_id, threat_level, reason)
        
      :high ->
        # Blocage complet + révocation des tokens + alerte
        RateLimiter.apply_temporary_block(user_id, reason, 7200) # 2 heures
        JwtValidator.revoke_user_tokens(user_id, reason)
        trigger_security_alert(user_id, threat_level, reason)
        
      :critical ->
        # Mesures maximales + escalade
        RateLimiter.apply_temporary_block(user_id, reason, 86400) # 24 heures
        JwtValidator.revoke_user_tokens(user_id, reason)
        trigger_security_alert(user_id, threat_level, reason)
        escalate_to_admin(user_id, threat_level, reason)
    end
  end

  ## Fonctions privées

  defp count_connections_for_ip(ip_string) do
    ip_connection_key = "ip_connections:#{ip_string}"
    
    case RedisConnection.command("SCARD", [ip_connection_key]) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Vérifier si un utilisateur est temporairement bloqué
  """
  def check_user_blocks(user_id) do
    case RateLimiter.check_temporary_block(user_id) do
      {:ok, :not_blocked} -> :ok
      {:ok, {:blocked, block_data}} -> 
        {:error, {:user_blocked, block_data}}
    end
  end

  defp validate_content_safety(message) do
    # Validation basique de sécurité du contenu
    cond do
      # Vérifier les caractères de contrôle malveillants
      String.contains?(message, [<<0>>, <<1>>, <<2>>]) ->
        {:error, :malicious_control_characters}
        
      # Vérifier la longueur excessive de lignes (potentiel DoS)
      String.split(message, "\n") |> Enum.any?(fn line -> String.length(line) > 1000 end) ->
        {:error, :excessive_line_length}
        
      # Autres vérifications de base
      true ->
        :ok
    end
  end

  defp check_suspicious_patterns(user_id, _context) do
    # Vérifier les patterns suspects récents
    pattern_key = "suspicious_patterns:#{user_id}"
    
    case RedisConnection.command("GET", [pattern_key]) do
      {:ok, nil} -> :ok
      {:ok, count_str} ->
        count = String.to_integer(count_str)
        if count >= @suspicious_patterns_threshold do
          {:error, :suspicious_behavior_detected}
        else
          :ok
        end
      {:error, _} -> :ok # Fail open
    end
  end

  defp calculate_activity_metrics(user_id) do
    # Calculer les métriques d'activité pour détection
    _now = DateTime.utc_now() |> DateTime.to_unix()
    
    # Ces métriques seraient normalement calculées depuis l'historique Redis
    %{
      message_count: get_recent_activity_count(user_id, "message", 60),
      connection_attempts: get_recent_activity_count(user_id, "connection", 300),
      channel_joins: get_recent_activity_count(user_id, "channel_join", 60),
      time_window: 60
    }
  end

  defp get_recent_activity_count(user_id, activity_type, _window_seconds) do
    # Récupérer le compteur d'activité récente
    key = "activity:#{user_id}:#{activity_type}"
    
    case RedisConnection.command("GET", [key]) do
      {:ok, nil} -> 0
      {:ok, count_str} -> String.to_integer(count_str)
      {:error, _} -> 0
    end
  end

  defp get_remote_ip(socket) do
    case socket.assigns[:peer_data] do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _ -> "unknown"
    end
  end

  defp get_remote_ip_from_conn(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _ -> "unknown"
    end
  end

  defp extract_token_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  ## Notifications et alertes

  defp notify_security_incident(user_id, threat_level, reason) do
    Logger.warning("Security incident detected", %{
      user_id: user_id,
      threat_level: threat_level,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
    
    # TODO: Envoyer vers un système de monitoring externe
  end

  defp trigger_security_alert(user_id, threat_level, reason) do
    Logger.error("Security alert triggered", %{
      user_id: user_id,
      threat_level: threat_level,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
    
    # TODO: Déclencher des alertes temps réel pour l'équipe sécurité
  end

  defp escalate_to_admin(user_id, threat_level, reason) do
    Logger.critical("Security escalation", %{
      user_id: user_id,
      threat_level: threat_level,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
    
    # TODO: Escalade automatique vers les administrateurs
  end

  ## Fonctions utilitaires pour les tests

  @doc """
  Obtenir les statistiques de sécurité pour un utilisateur
  """
  def get_security_stats(user_id) do
    %{
      is_blocked: RateLimiter.check_temporary_block(user_id),
      recent_activity: calculate_activity_metrics(user_id),
      suspicious_patterns: get_recent_activity_count(user_id, "suspicious", 3600)
    }
  end

  @doc """
  Réinitialiser les compteurs de sécurité pour un utilisateur (admin only)
  """
  def reset_security_counters(user_id, admin_user_id) do
    Logger.info("Security counters reset", %{
      user_id: user_id,
      admin_user_id: admin_user_id
    })
    
    # Supprimer les compteurs et blocages temporaires
    keys_to_delete = [
      "temp_block:#{user_id}",
      "suspicious_patterns:#{user_id}",
      "rate_limit:user:#{user_id}:*"
    ]
    
    # Note: En production, utiliser SCAN pour les patterns avec *
    Enum.each(keys_to_delete, fn key ->
      if not String.contains?(key, "*") do
        RedisConnection.command("DEL", [key])
      end
    end)
    
    :ok
  end
end
