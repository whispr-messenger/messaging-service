defmodule WhisprMessaging.Security.AuthPlug do
  @moduledoc """
  Plug d'authentification JWT pour sécuriser les endpoints API
  selon les spécifications de sécurité du projet
  """
  
  import Plug.Conn
  require Logger
  
  alias WhisprMessaging.Security.JwtValidator

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        validate_and_assign_user(conn, token)
      {:error, reason} ->
        handle_auth_error(conn, reason)
    end
  end

  @doc """
  Extrait le token JWT depuis les headers de la requête
  """
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        {:ok, String.trim(token)}
      ["bearer " <> token] ->
        {:ok, String.trim(token)}
      [] ->
        # Vérifier aussi dans les paramètres de query (pour WebSockets)
        case conn.params["token"] do
          token when is_binary(token) and token != "" ->
            {:ok, token}
          _ ->
            {:error, :missing_token}
        end
      [invalid_header] ->
        Logger.warning("Invalid authorization header format", %{header: invalid_header})
        {:error, :invalid_auth_header}
      multiple_headers ->
        Logger.warning("Multiple authorization headers", %{headers: multiple_headers})
        {:error, :multiple_auth_headers}
    end
  end

  @doc """
  Valide le token et assigne les informations utilisateur à la connexion
  """
  defp validate_and_assign_user(conn, token) do
    case JwtValidator.quick_validate_token(token) do
      {:ok, user_data} ->
        conn
        |> assign(:current_user, user_data)
        |> assign(:user_id, user_data["sub"])
        |> assign(:device_id, user_data["device_id"])
        |> assign(:token_claims, user_data)
        |> put_resp_header("x-user-id", user_data["sub"])
        
      {:error, reason} ->
        handle_auth_error(conn, reason)
    end
  end

  @doc """
  Gère les erreurs d'authentification
  """
  defp handle_auth_error(conn, reason) do
    {status_code, error_message, error_code} = map_auth_error(reason)
    
    # Log de sécurité
    log_auth_failure(conn, reason)
    
    # Réponse d'erreur
    conn
    |> put_status(status_code)
    |> put_resp_content_type("application/json")
    |> send_resp(status_code, Jason.encode!(%{
      error: error_code,
      message: error_message,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }))
    |> halt()
  end

  @doc """
  Mappe les erreurs d'authentification vers des codes HTTP et messages
  """
  defp map_auth_error(reason) do
    case reason do
      :missing_token ->
        {401, "Token d'authentification requis", "missing_token"}
      :invalid_auth_header ->
        {401, "Format d'en-tête d'autorisation invalide", "invalid_header"}
      :multiple_auth_headers ->
        {401, "Plusieurs en-têtes d'autorisation détectés", "multiple_headers"}
      :token_expired ->
        {401, "Token expiré", "token_expired"}
      :token_not_yet_valid ->
        {401, "Token pas encore valide", "token_not_yet_valid"}
      :token_too_old ->
        {401, "Token trop ancien", "token_too_old"}
      :token_from_future ->
        {401, "Token du futur détecté", "token_from_future"}
      :token_revoked ->
        {401, "Token révoqué", "token_revoked"}
      :token_replay_detected ->
        {401, "Tentative de rejeu de token détectée", "token_replay"}
      :signature_verification_failed ->
        {401, "Signature du token invalide", "invalid_signature"}
      :invalid_token_format ->
        {401, "Format de token invalide", "invalid_format"}
      :unsupported_algorithm ->
        {401, "Algorithme de signature non supporté", "unsupported_algorithm"}
      :auth_service_unavailable ->
        {503, "Service d'authentification indisponible", "auth_service_down"}
      :key_not_found ->
        {401, "Clé de vérification introuvable", "key_not_found"}
      _ ->
        {401, "Authentification échouée", "auth_failed"}
    end
  end

  @doc """
  Log les échecs d'authentification pour la sécurité
  """
  defp log_auth_failure(conn, reason) do
    remote_ip = get_remote_ip(conn)
    user_agent = get_req_header(conn, "user-agent") |> List.first()
    
    Logger.warning("Authentication failure", %{
      reason: reason,
      remote_ip: remote_ip,
      user_agent: user_agent,
      path: conn.request_path,
      method: conn.method,
      timestamp: DateTime.utc_now()
    })
    
    # Incrémenter les métriques de sécurité
    :telemetry.execute([:whispr_messaging, :auth, :failure], %{count: 1}, %{
      reason: reason,
      remote_ip: remote_ip
    })
  end

  @doc """
  Extrait l'adresse IP réelle du client
  """
  defp get_remote_ip(conn) do
    # Vérifier les headers de proxy en premier
    forwarded_for = get_req_header(conn, "x-forwarded-for") |> List.first()
    real_ip = get_req_header(conn, "x-real-ip") |> List.first()
    
    cond do
      forwarded_for && forwarded_for != "" ->
        # Prendre la première IP de la liste (client original)
        forwarded_for |> String.split(",") |> List.first() |> String.trim()
      real_ip && real_ip != "" ->
        real_ip
      true ->
        # Fallback vers l'IP de la connexion
        case conn.remote_ip do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          {a, b, c, d, e, f, g, h} -> 
            # IPv6
            [a, b, c, d, e, f, g, h]
            |> Enum.map(&Integer.to_string(&1, 16))
            |> Enum.join(":")
          _ -> "unknown"
        end
    end
  end

  @doc """
  Plug optionnel pour vérifier des permissions spécifiques
  """
  def require_permission(conn, permission) when is_binary(permission) do
    case conn.assigns[:token_claims] do
      %{"permissions" => permissions} when is_list(permissions) ->
        if permission in permissions do
          conn
        else
          handle_permission_error(conn, permission)
        end
      _ ->
        handle_permission_error(conn, permission)
    end
  end

  defp handle_permission_error(conn, permission) do
    Logger.warning("Permission denied", %{
      user_id: conn.assigns[:user_id],
      required_permission: permission,
      path: conn.request_path
    })
    
    conn
    |> put_status(403)
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{
      error: "insufficient_permissions",
      message: "Permission requise : #{permission}",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }))
    |> halt()
  end
end