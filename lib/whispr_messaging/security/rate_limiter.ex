defmodule WhisprMessaging.Security.RateLimiter do
  @moduledoc """
  Rate limiting distribué avec Redis selon les spécifications anti_harassment.md
  """
  
  alias WhisprMessaging.Cache.RedisConnection
  
  require Logger

  # Limites de base par type d'action (par heure)
  @base_limits %{
    "message" => 1000,
    "media" => 100,
    "group_creation" => 10,
    "contact_add" => 50,
    "report" => 20,
    "search" => 500,
    "typing" => 1000,
    "connection" => 200
  }

  # Limites par IP (par heure)
  @ip_limits %{
    "connection" => 100,
    "registration" => 10,
    "auth_attempts" => 20
  }

  # Facteurs multiplicateurs par niveau de confiance
  @trust_factors %{
    "suspect" => 0.1,
    "normal" => 1.0,
    "verified" => 2.0,
    "premium" => 3.0
  }

  @doc """
  Vérifier si une action est autorisée pour un utilisateur
  """
  def check_rate_limit(user_id, action_type, options \\ []) do
    trust_level = Keyword.get(options, :trust_level, "normal")
    _context = Keyword.get(options, :context, %{})
    
    # Calculer la limite dynamique pour cet utilisateur
    dynamic_limit = calculate_dynamic_limit(user_id, action_type, trust_level)
    
    # Obtenir l'utilisation actuelle
    case get_current_usage(user_id, action_type) do
      {:ok, current_usage} ->
        if current_usage >= dynamic_limit do
          # Limite dépassée
          backoff_time = calculate_backoff_delay(user_id, action_type, current_usage - dynamic_limit)
          
          Logger.warning("Rate limit exceeded", %{
            user_id: user_id,
            action_type: action_type,
            current_usage: current_usage,
            limit: dynamic_limit,
            backoff_time: backoff_time
          })
          
          {:error, {:rate_limit_exceeded, %{
            retry_after: backoff_time,
            limit: dynamic_limit,
            current: current_usage
          }}}
        else
          # Action autorisée, incrémenter le compteur
          increment_usage(user_id, action_type)
          
          {:ok, %{
            allowed: true,
            remaining: dynamic_limit - current_usage - 1,
            limit: dynamic_limit,
            reset_time: get_reset_time(action_type)
          }}
        end
        
      {:error, reason} ->
        Logger.error("Failed to check rate limit", %{
          user_id: user_id,
          action_type: action_type,
          error: reason
        })
        # En cas d'erreur Redis, autoriser mais logger
        {:ok, %{allowed: true, remaining: 999, limit: 1000}}
    end
  end

  @doc """
  Vérifier les limites par IP
  """
  def check_ip_rate_limit(ip_address, action_type, _options \\ []) do
    limit = Map.get(@ip_limits, action_type, 100)
    key = ip_rate_key(ip_address, action_type)
    
    case get_current_count(key) do
      {:ok, current_count} ->
        if current_count >= limit do
          backoff_time = calculate_ip_backoff(ip_address, action_type)
          
          Logger.warning("IP rate limit exceeded", %{
            ip_address: ip_address,
            action_type: action_type,
            current_count: current_count,
            limit: limit
          })
          
          {:error, {:ip_rate_limit_exceeded, %{
            retry_after: backoff_time,
            limit: limit
          }}}
        else
          increment_ip_usage(ip_address, action_type)
          {:ok, %{allowed: true, remaining: limit - current_count - 1}}
        end
        
      {:error, reason} ->
        Logger.error("Failed to check IP rate limit", %{error: reason})
        {:ok, %{allowed: true, remaining: 99}}
    end
  end

  @doc """
  Appliquer un blocage temporaire pour comportement suspect
  """
  def apply_temporary_block(user_id, reason, duration_seconds \\ 300) do
    key = block_key(user_id)
    
    block_data = %{
      reason: reason,
      blocked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration: duration_seconds,
      expires_at: DateTime.utc_now() |> DateTime.add(duration_seconds, :second) |> DateTime.to_iso8601()
    }
    
    case RedisConnection.command("SETEX", [key, duration_seconds, Jason.encode!(block_data)]) do
      {:ok, "OK"} ->
        Logger.warning("User temporarily blocked", %{
          user_id: user_id,
          reason: reason,
          duration: duration_seconds
        })
        :ok
        
      {:error, redis_error} ->
        Logger.error("Failed to apply temporary block", %{
          user_id: user_id,
          error: redis_error
        })
        {:error, redis_error}
    end
  end

  @doc """
  Vérifier si un utilisateur est temporairement bloqué
  """
  def check_temporary_block(user_id) do
    key = block_key(user_id)
    
    case RedisConnection.command("GET", [key]) do
      {:ok, nil} ->
        {:ok, :not_blocked}
        
      {:ok, block_json} ->
        case Jason.decode(block_json) do
          {:ok, block_data} ->
            {:ok, {:blocked, block_data}}
          {:error, _} ->
            # Données corrompues, supprimer le blocage
            RedisConnection.command("DEL", [key])
            {:ok, :not_blocked}
        end
        
      {:error, reason} ->
        Logger.error("Failed to check temporary block", %{
          user_id: user_id,
          error: reason
        })
        {:ok, :not_blocked} # En cas d'erreur, ne pas bloquer
    end
  end

  @doc """
  Détecter une activité suspecte et appliquer des mesures
  """
  def detect_suspicious_activity(user_id, activity_data) do
    patterns = [
      check_message_spam(user_id, activity_data),
      check_connection_abuse(user_id, activity_data),
      check_channel_hopping(user_id, activity_data),
      check_rapid_fire_messages(user_id, activity_data)
    ]
    
    case Enum.find(patterns, fn result -> result != :ok end) do
      nil -> 
        :ok
        
      {:suspicious, reason, severity} ->
        handle_suspicious_behavior(user_id, reason, severity)
    end
  end

  ## Fonctions privées

  defp calculate_dynamic_limit(user_id, action_type, trust_level) do
    base_limit = Map.get(@base_limits, action_type, 100)
    trust_factor = Map.get(@trust_factors, trust_level, 1.0)
    
    # Facteurs additionnels
    activity_factor = get_activity_factor(user_id)
    reputation_factor = get_reputation_factor(user_id)
    temporal_factor = get_temporal_factor()
    
    # Calcul de la limite finale
    dynamic_limit = base_limit * trust_factor * activity_factor * reputation_factor * temporal_factor
    
    # Contraintes min/max
    min_limit = trunc(base_limit * 0.1)
    max_limit = trunc(base_limit * 3.0)
    
    dynamic_limit
    |> trunc()
    |> max(min_limit)
    |> min(max_limit)
  end

  defp get_current_usage(user_id, action_type) do
    key = user_rate_key(user_id, action_type)
    get_current_count(key)
  end

  defp get_current_count(key) do
    case RedisConnection.command("GET", [key]) do
      {:ok, nil} -> {:ok, 0}
      {:ok, count_str} -> {:ok, String.to_integer(count_str)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp increment_usage(user_id, action_type) do
    key = user_rate_key(user_id, action_type)
    ttl = get_window_ttl(action_type)
    
    # Utiliser pipeline pour atomicité
    commands = [
      ["INCR", key],
      ["EXPIRE", key, ttl]
    ]
    
    RedisConnection.pipeline(commands)
  end

  defp increment_ip_usage(ip_address, action_type) do
    key = ip_rate_key(ip_address, action_type)
    ttl = get_window_ttl(action_type)
    
    commands = [
      ["INCR", key],
      ["EXPIRE", key, ttl]
    ]
    
    RedisConnection.pipeline(commands)
  end

  defp calculate_backoff_delay(_user_id, _action_type, excess_amount) do
    # Délai exponentiel basé sur le dépassement
    base_delay = 60 # 1 minute de base
    excess_factor = min(excess_amount, 10) # Limiter le facteur d'excès
    
    trunc(base_delay * :math.pow(1.5, excess_factor))
  end

  defp calculate_ip_backoff(_ip_address, _action_type) do
    # Délai plus long pour les IPs abusives
    300 # 5 minutes
  end

  defp get_activity_factor(_user_id) do
    # Facteur basé sur l'activité récente (à implémenter)
    # Pour l'instant, facteur neutre
    1.0
  end

  defp get_reputation_factor(_user_id) do
    # Facteur basé sur la réputation (à implémenter avec user-service)
    # Pour l'instant, facteur neutre
    1.0
  end

  defp get_temporal_factor do
    # Facteur basé sur l'heure (plus strict en heures de pointe)
    hour = DateTime.utc_now().hour
    case hour do
      h when h >= 8 and h <= 22 -> 0.8 # Heures de pointe, plus strict
      _ -> 1.2 # Heures creuses, plus permissif
    end
  end

  defp get_window_ttl(action_type) do
    case action_type do
      action when action in ["group_creation", "contact_add", "report"] -> 86400 # 24h
      _ -> 3600 # 1h pour la plupart des actions
    end
  end

  defp get_reset_time(action_type) do
    ttl = get_window_ttl(action_type)
    DateTime.utc_now() |> DateTime.add(ttl, :second)
  end

  ## Détection d'activité suspecte

  defp check_message_spam(_user_id, %{message_count: count, time_window: window}) 
       when count > 50 and window < 60 do
    {:suspicious, :message_spam, :medium}
  end
  defp check_message_spam(_user_id, _activity), do: :ok

  defp check_connection_abuse(_user_id, %{connection_attempts: attempts, time_window: window})
       when attempts > 20 and window < 300 do
    {:suspicious, :connection_abuse, :high}
  end
  defp check_connection_abuse(_user_id, _activity), do: :ok

  defp check_channel_hopping(_user_id, %{channel_joins: joins, time_window: window})
       when joins > 30 and window < 60 do
    {:suspicious, :channel_hopping, :medium}
  end
  defp check_channel_hopping(_user_id, _activity), do: :ok

  defp check_rapid_fire_messages(_user_id, %{consecutive_messages: count, time_span: span})
       when count > 10 and span < 10 do
    {:suspicious, :rapid_fire, :low}
  end
  defp check_rapid_fire_messages(_user_id, _activity), do: :ok

  defp handle_suspicious_behavior(user_id, reason, severity) do
    duration = case severity do
      :low -> 60      # 1 minute
      :medium -> 300  # 5 minutes
      :high -> 1800   # 30 minutes
    end
    
    apply_temporary_block(user_id, reason, duration)
    
    # Notifier les administrateurs pour les cas sévères
    if severity in [:medium, :high] do
      notify_security_team(user_id, reason, severity)
    end
    
    {:blocked, reason, duration}
  end

  defp notify_security_team(user_id, reason, severity) do
    # TODO: Implémenter notification aux administrateurs
    Logger.warning("Security alert", %{
      user_id: user_id,
      reason: reason,
      severity: severity,
      timestamp: DateTime.utc_now()
    })
  end

  ## Clés Redis

  defp user_rate_key(user_id, action_type) do
    "rate_limit:user:#{user_id}:#{action_type}"
  end

  defp ip_rate_key(ip_address, action_type) do
    "rate_limit:ip:#{ip_address}:#{action_type}"
  end

  defp block_key(user_id) do
    "temp_block:#{user_id}"
  end
end
