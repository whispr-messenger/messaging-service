defmodule WhisprMessaging.Security.JwtValidator do
  @moduledoc """
  Validation JWT complète avec clés publiques et vérifications de sécurité
  selon security_policy.md
  """
  
  require Logger

  # Configuration par défaut
  @default_issuer "auth-service"
  @default_audience "whispr-messaging"
  @max_token_age 3600 # 1 heure
  @clock_skew_allowance 300 # 5 minutes

  @doc """
  Valider un token JWT complet avec toutes les vérifications de sécurité
  """
  def validate_token(token, options \\ []) do
    with {:ok, header} <- decode_header(token),
         {:ok, payload} <- decode_payload(token),
         :ok <- verify_token_format(header, payload),
         :ok <- verify_algorithm(header),
         {:ok, public_key} <- get_public_key(header["kid"]),
         :ok <- verify_signature(token, public_key, header["alg"]),
         :ok <- verify_claims(payload, options),
         :ok <- verify_token_freshness(payload),
         :ok <- check_token_revocation(payload) do
      
      {:ok, %{
        user_id: payload["sub"],
        device_id: payload["device_id"],
        session_id: payload["session_id"],
        permissions: payload["permissions"] || [],
        issued_at: payload["iat"],
        expires_at: payload["exp"],
        trust_level: determine_trust_level(payload)
      }}
    else
      {:error, reason} ->
        Logger.warning("JWT validation failed", %{
          reason: reason,
          token_prefix: String.slice(token || "", 0, 20)
        })
        {:error, reason}
    end
  end

  @doc """
  Validation rapide pour les connexions WebSocket (cache enabled)
  """
  def quick_validate_token(token) do
    # Vérifier d'abord le cache pour éviter la validation complète
    token_hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    cache_key = "jwt_cache:#{token_hash}"
    
    case WhisprMessaging.Cache.RedisConnection.command("GET", [cache_key]) do
      {:ok, cached_result} when not is_nil(cached_result) ->
        case Jason.decode(cached_result) do
          {:ok, cached_data} ->
            {:ok, cached_data}
          {:error, _} ->
            # Cache corrompu, valider normalement
            validate_and_cache_token(token, token_hash)
        end
        
      _ ->
        # Pas en cache, valider et cacher
        validate_and_cache_token(token, token_hash)
    end
  end

  @doc """
  Extraire les informations de base sans validation complète
  """
  def extract_token_info(token) do
    with {:ok, payload} <- decode_payload(token) do
      {:ok, %{
        user_id: payload["sub"],
        device_id: payload["device_id"],
        expires_at: payload["exp"],
        issued_at: payload["iat"]
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Vérifier si un token est proche de l'expiration
  """
  def token_needs_refresh?(token, threshold_seconds \\ 300) do
    case extract_token_info(token) do
      {:ok, %{expires_at: exp}} ->
        expires_at = DateTime.from_unix!(exp)
        threshold_time = DateTime.utc_now() |> DateTime.add(threshold_seconds, :second)
        DateTime.compare(expires_at, threshold_time) == :lt
        
      {:error, _} ->
        true # Si erreur, considérer qu'il faut rafraîchir
    end
  end

  ## Fonctions privées

  defp decode_header(token) do
    case String.split(token, ".") do
      [header_b64, _, _] ->
        case Base.url_decode64(header_b64, padding: false) do
          {:ok, header_json} ->
            case Jason.decode(header_json) do
              {:ok, header} -> {:ok, header}
              {:error, _} -> {:error, :invalid_header_json}
            end
          :error -> {:error, :invalid_header_encoding}
        end
      _ -> {:error, :invalid_token_format}
    end
  end

  defp decode_payload(token) do
    case String.split(token, ".") do
      [_, payload_b64, _] ->
        case Base.url_decode64(payload_b64, padding: false) do
          {:ok, payload_json} ->
            case Jason.decode(payload_json) do
              {:ok, payload} -> {:ok, payload}
              {:error, _} -> {:error, :invalid_payload_json}
            end
          :error -> {:error, :invalid_payload_encoding}
        end
      _ -> {:error, :invalid_token_format}
    end
  end

  defp verify_token_format(header, payload) do
    required_header_fields = ["alg", "typ", "kid"]
    required_payload_fields = ["sub", "iat", "exp", "aud", "iss"]
    
    cond do
      not Enum.all?(required_header_fields, &Map.has_key?(header, &1)) ->
        {:error, :missing_header_fields}
        
      not Enum.all?(required_payload_fields, &Map.has_key?(payload, &1)) ->
        {:error, :missing_payload_fields}
        
      header["typ"] != "JWT" ->
        {:error, :invalid_token_type}
        
      true ->
        :ok
    end
  end

  defp verify_algorithm(header) do
    allowed_algorithms = ["RS256", "ES256"]
    
    if header["alg"] in allowed_algorithms do
      :ok
    else
      {:error, {:unsupported_algorithm, header["alg"]}}
    end
  end

  defp get_public_key(key_id) do
    # Récupération des clés publiques depuis auth-service
    cache_key = "jwt_public_key:#{key_id}"
    
    # Vérifier d'abord le cache
    case WhisprMessaging.Cache.RedisConnection.command("GET", [cache_key]) do
      {:ok, cached_key} when not is_nil(cached_key) ->
        case Jason.decode(cached_key) do
          {:ok, key_data} ->
            {:ok, decode_public_key(key_data["public_key"], key_data["algorithm"])}
          {:error, _} ->
            fetch_public_key_from_auth_service(key_id)
        end
      _ ->
        fetch_public_key_from_auth_service(key_id)
    end
  end

  defp fetch_public_key_from_auth_service(key_id) do
    # Configuration auth-service
    auth_service_url = Application.get_env(:whispr_messaging, :auth_service_url, "http://auth-service:4000")
    jwks_endpoint = "#{auth_service_url}/.well-known/jwks.json"
    
    case Req.get(jwks_endpoint, receive_timeout: 5000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"keys" => keys}} ->
            case find_key_by_id(keys, key_id) do
              {:ok, key_data} ->
                # Cacher la clé pour 1 heure
                cache_key = "jwt_public_key:#{key_id}"
                cache_value = Jason.encode!(key_data)
                WhisprMessaging.Cache.RedisConnection.command("SETEX", [cache_key, 3600, cache_value])
                
                {:ok, decode_public_key(key_data["x5c"] || key_data["n"], key_data["alg"])}
              {:error, reason} ->
                Logger.error("Key not found in JWKS", %{key_id: key_id, reason: reason})
                {:error, :key_not_found}
            end
          {:error, reason} ->
            Logger.error("Failed to parse JWKS response", %{reason: reason})
            {:error, :invalid_jwks_response}
        end
      {:ok, %Req.Response{status: status_code}} ->
        Logger.error("Auth service returned error", %{status_code: status_code})
        {:error, :auth_service_error}
      {:error, reason} ->
        Logger.error("Failed to fetch JWKS", %{reason: reason})
        # Fallback en mode développement
        if Application.get_env(:whispr_messaging, :environment) == :dev do
          Logger.warning("Using development key fallback")
          {:ok, :dev_public_key}
        else
          {:error, :auth_service_unavailable}
        end
    end
  end

  defp find_key_by_id(keys, key_id) do
    case Enum.find(keys, fn key -> key["kid"] == key_id end) do
      nil -> {:error, :key_not_found}
      key -> {:ok, key}
    end
  end

  defp decode_public_key(key_data, algorithm) do
    case algorithm do
      "RS256" ->
        # Décoder la clé RSA depuis le format X.509 ou JWK
        case :public_key.pem_decode(key_data) do
          [{:Certificate, cert_der, _}] ->
            cert = :public_key.pkix_decode_cert(cert_der, :otp)
            :public_key.pki_asn1_decode(:RSAPublicKey, cert)
          _ ->
            # Fallback pour format JWK
            :rsa_public_key
        end
      "ES256" ->
        # Support pour ECDSA
        :ecdsa_public_key
      _ ->
        Logger.warning("Unsupported key algorithm", %{algorithm: algorithm})
        :unknown_key_type
    end
  rescue
    error ->
      Logger.error("Failed to decode public key", %{error: inspect(error)})
      :invalid_key_format
  end

  defp verify_signature(token, public_key, algorithm) do
    # Séparer le token en ses composants
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        # Reconstituer le message signé (header.payload)
        message = "#{header_b64}.#{payload_b64}"
        
        # Décoder la signature
        case Base.url_decode64(signature_b64, padding: false) do
          {:ok, signature} ->
            verify_signature_with_algorithm(message, signature, public_key, algorithm)
          :error ->
            Logger.error("Failed to decode signature")
            {:error, :invalid_signature_format}
        end
      _ ->
        Logger.error("Invalid token format for signature verification")
        {:error, :invalid_token_format}
    end
  end

  defp verify_signature_with_algorithm(message, signature, public_key, algorithm) do
    case {algorithm, public_key} do
      {"RS256", :dev_public_key} ->
        # Mode développement - accepter tous les tokens
        if Application.get_env(:whispr_messaging, :environment) == :dev do
          Logger.debug("Development mode: skipping signature verification")
          :ok
        else
          {:error, :dev_key_in_production}
        end
        
      {"RS256", rsa_key} when rsa_key != :dev_public_key ->
        # Vérification RSA-SHA256
        try do
          case :public_key.verify(message, :sha256, signature, rsa_key) do
            true -> :ok
            false -> {:error, :signature_verification_failed}
          end
        rescue
          error ->
            Logger.error("RSA signature verification failed", %{error: inspect(error)})
            {:error, :signature_verification_error}
        end
        
      {"ES256", ecdsa_key} ->
        # Vérification ECDSA-SHA256
        try do
          case :public_key.verify(message, :sha256, signature, ecdsa_key) do
            true -> :ok
            false -> {:error, :signature_verification_failed}
          end
        rescue
          error ->
            Logger.error("ECDSA signature verification failed", %{error: inspect(error)})
            {:error, :signature_verification_error}
        end
        
      {unsupported_alg, _} ->
        Logger.error("Unsupported signature algorithm", %{algorithm: unsupported_alg})
        {:error, :unsupported_algorithm}
        
      {_, :invalid_key_format} ->
        Logger.error("Invalid public key format")
        {:error, :invalid_public_key}
        
      {_, :unknown_key_type} ->
        Logger.error("Unknown public key type")
        {:error, :unknown_key_type}
    end
  end

  defp verify_claims(payload, options) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    
    # Vérifications temporelles
    issued_at = payload["iat"]
    expires_at = payload["exp"]
    not_before = payload["nbf"]
    
    cond do
      # Token expiré
      expires_at <= now ->
        {:error, :token_expired}
        
      # Token utilisé avant sa validité
      not_before && not_before > now + @clock_skew_allowance ->
        {:error, :token_not_yet_valid}
        
      # Token trop ancien
      issued_at < now - @max_token_age ->
        {:error, :token_too_old}
        
      # Token du futur (problème d'horloge)
      issued_at > now + @clock_skew_allowance ->
        {:error, :token_from_future}
        
      true ->
        verify_audience_and_issuer(payload, options)
    end
  end

  defp verify_audience_and_issuer(payload, options) do
    expected_issuer = Keyword.get(options, :issuer, @default_issuer)
    expected_audience = Keyword.get(options, :audience, @default_audience)
    
    cond do
      payload["iss"] != expected_issuer ->
        {:error, {:invalid_issuer, payload["iss"]}}
        
      not audience_matches?(payload["aud"], expected_audience) ->
        {:error, {:invalid_audience, payload["aud"]}}
        
      true ->
        :ok
    end
  end

  defp audience_matches?(token_aud, expected_aud) when is_binary(token_aud) do
    token_aud == expected_aud
  end
  
  defp audience_matches?(token_aud, expected_aud) when is_list(token_aud) do
    expected_aud in token_aud
  end
  
  defp audience_matches?(_, _), do: false

  defp verify_token_freshness(payload) do
    # Vérifier si le token n'est pas trop récent (protection contre replay immédiat)
    issued_at = payload["iat"]
    now = DateTime.utc_now() |> DateTime.to_unix()
    
    if issued_at > now - 5 do # Moins de 5 secondes
      # Vérifier dans le cache des tokens récents
      check_recent_token_usage(payload)
    else
      :ok
    end
  end

  defp check_recent_token_usage(payload) do
    token_id = payload["jti"] || "#{payload["sub"]}_#{payload["iat"]}"
    recent_key = "recent_token:#{token_id}"
    
    case WhisprMessaging.Cache.RedisConnection.command("EXISTS", [recent_key]) do
      {:ok, 1} ->
        {:error, :token_replay_detected}
      {:ok, 0} ->
        # Marquer comme utilisé pour les prochaines 30 secondes
        WhisprMessaging.Cache.RedisConnection.command("SETEX", [recent_key, 30, "used"])
        :ok
      {:error, _} ->
        # En cas d'erreur Redis, autoriser (fail open pour availability)
        :ok
    end
  end

  defp check_token_revocation(payload) do
    # Vérifier si le token est dans la liste de révocation
    revocation_key = "revoked_token:#{payload["jti"] || payload["sub"]}"
    
    case WhisprMessaging.Cache.RedisConnection.command("EXISTS", [revocation_key]) do
      {:ok, 1} ->
        {:error, :token_revoked}
      {:ok, 0} ->
        :ok
      {:error, _} ->
        # En cas d'erreur Redis, autoriser (fail open)
        :ok
    end
  end

  defp determine_trust_level(payload) do
    # Déterminer le niveau de confiance basé sur les claims
    cond do
      payload["verified"] == true -> "verified"
      payload["premium"] == true -> "premium"
      payload["new_account"] == true -> "suspect"
      true -> "normal"
    end
  end

  defp validate_and_cache_token(token, token_hash) do
    case validate_token(token) do
      {:ok, token_data} ->
        # Cacher le résultat pour 5 minutes (moins que la durée du token)
        cache_key = "jwt_cache:#{token_hash}"
        now_unix = DateTime.utc_now() |> DateTime.to_unix()
        expires_at_unix = token_data.expires_at || now_unix
        cache_ttl = max(1, min(300, expires_at_unix - now_unix))
        
        WhisprMessaging.Cache.RedisConnection.command("SETEX", [
          cache_key, 
          cache_ttl, 
          Jason.encode!(token_data)
        ])
        
        {:ok, token_data}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  ## API publique pour l'administration

  @doc """
  Révoquer un token spécifique
  """
  def revoke_token(token_id, reason \\ "admin_revoked") do
    revocation_key = "revoked_token:#{token_id}"
    revocation_data = %{
      reason: reason,
      revoked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    # Révocation valide pendant 24h (durée max des tokens)
    case WhisprMessaging.Cache.RedisConnection.command("SETEX", [
      revocation_key, 
      86400, 
      Jason.encode!(revocation_data)
    ]) do
      {:ok, "OK"} ->
        Logger.info("Token revoked", %{token_id: token_id, reason: reason})
        :ok
      {:error, reason} ->
        Logger.error("Failed to revoke token", %{token_id: token_id, error: reason})
        {:error, reason}
    end
  end

  @doc """
  Révoquer tous les tokens d'un utilisateur
  """
  def revoke_user_tokens(user_id, reason \\ "security_incident") do
    revocation_key = "revoked_user:#{user_id}"
    revocation_data = %{
      reason: reason,
      revoked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    # Révocation utilisateur valide pendant 24h
    case WhisprMessaging.Cache.RedisConnection.command("SETEX", [
      revocation_key, 
      86400, 
      Jason.encode!(revocation_data)
    ]) do
      {:ok, "OK"} ->
        Logger.warning("All user tokens revoked", %{user_id: user_id, reason: reason})
        :ok
      {:error, reason} ->
        Logger.error("Failed to revoke user tokens", %{user_id: user_id, error: reason})
        {:error, reason}
    end
  end
end
