defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  WebSocket connection handler for user sessions.

  Handles authentication, presence tracking, and channel subscriptions.
  Validates JWT tokens using the same JWKS-based flow as the HTTP Authenticate plug.

  Tous les rejets d'auth emettent un log JSON structure (WHISPR-1240) avec :
  event, reason, socket_id, remote_ip, user_agent, user_id (si extractible).
  Le token JWT lui-meme n'est jamais loggue.
  """

  use Phoenix.Socket
  require Logger

  alias WhisprMessaging.JwksCache

  # Channels
  channel "conversation:*", WhisprMessagingWeb.ConversationChannel
  channel "user:*", WhisprMessagingWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) when token != "" do
    meta = extract_conn_meta(connect_info)

    case verify_jwt(token) do
      {:ok, user_id, device_id} ->
        socket =
          socket
          |> assign(:user_id, user_id)
          |> assign(:device_id, device_id)

        {:ok, socket}

      {:error, reason} ->
        # user_id partiel : si le sub est lisible malgre l'echec (ex: signature invalide),
        # on le logue pour correlations SOC. Sinon nil.
        user_id = peek_sub(token)

        log_ws_auth_rejected(reason, socket, meta, user_id)
        :error
    end
  end

  def connect(_params, socket, connect_info) do
    meta = extract_conn_meta(connect_info)
    log_ws_auth_rejected(:missing_token, socket, meta, nil)
    :error
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # WHISPR-1214 — audiences acceptees sur la socket :
  #   * `nil` : access tokens HTTP actuels (pas d'aud claim cote auth-service)
  #   * `"whispr"` : audience HTTP historique
  #   * `"ws"` : token court-vivant (60 s) emis par /tokens/ws-token
  # Toute autre valeur est rejetee. Public uniquement pour le unit test.
  @doc false
  def valid_aud?(nil), do: true
  def valid_aud?(aud) when is_binary(aud), do: aud in ["whispr", "ws"]
  def valid_aud?(_), do: false

  # ---------------------------------------------------------------------------
  # Logging structure des rejets (WHISPR-1240)
  # ---------------------------------------------------------------------------

  # Mappe les raisons d'echec Joken/internes vers des codes SOC stables.
  @reason_map %{
    missing_token: "missing",
    missing_kid: "malformed",
    jwks_not_loaded: "jwks_unavailable",
    "missing or invalid sub claim": "malformed"
  }

  defp log_ws_auth_rejected(reason, socket, meta, user_id) do
    reason_code = Map.get(@reason_map, reason) || classify_joken_error(reason)

    Logger.warning("ws_auth_rejected",
      event: "ws_auth_rejected",
      reason: reason_code,
      socket_id: socket_id_safe(socket),
      remote_ip: meta.remote_ip,
      user_agent: meta.user_agent,
      user_id: user_id,
      domain: :socket
    )
  end

  # Joken renvoie des erreurs variees selon le type d'echec de validation.
  # On normalise pour le SOC sans exposer d'info interne sur la cle/algo.
  defp classify_joken_error({:error, [message: "Invalid token", claim: "exp", claim_val: _]}),
    do: "expired"

  defp classify_joken_error({:error, [message: "Invalid token", claim: "iss", claim_val: _]}),
    do: "invalid_issuer"

  defp classify_joken_error({:error, [message: "Invalid token", claim: "aud", claim_val: _]}),
    do: "invalid_audience"

  defp classify_joken_error({:error, :signature_error}), do: "invalid_signature"
  defp classify_joken_error({:error, :token_malformed}), do: "malformed"
  defp classify_joken_error(_), do: "invalid_token"

  # socket.assigns peut ne pas avoir :user_id si la connexion est rejetee avant assign
  defp socket_id_safe(%Phoenix.Socket{assigns: %{user_id: uid}}) when is_binary(uid),
    do: "user_socket:#{uid}"

  defp socket_id_safe(_), do: nil

  # Extrait IP et User-Agent depuis connect_info (fourni par l'endpoint, WHISPR-1240).
  # peer_data est la connexion directe TCP ; x_headers contient X-Forwarded-For
  # quand le service est derriere un ingress/proxy (cas preprod/prod Citadel).
  defp extract_conn_meta(connect_info) do
    remote_ip = extract_remote_ip(connect_info)
    user_agent = extract_user_agent(connect_info)
    %{remote_ip: remote_ip, user_agent: user_agent}
  end

  defp extract_remote_ip(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "x-forwarded-for", 0) do
      {_, ip} -> ip |> String.split(",") |> List.first() |> String.trim()
      nil -> extract_peer_ip(headers)
    end
  end

  defp extract_remote_ip(connect_info), do: extract_peer_ip(connect_info)

  defp extract_peer_ip(%{peer_data: %{address: addr}}) when not is_nil(addr) do
    addr |> :inet.ntoa() |> to_string()
  end

  defp extract_peer_ip(_), do: nil

  defp extract_user_agent(%{x_headers: headers}) when is_list(headers) do
    case List.keyfind(headers, "user-agent", 0) do
      {_, ua} -> ua
      nil -> nil
    end
  end

  defp extract_user_agent(_), do: nil

  # ---------------------------------------------------------------------------
  # JWT verification
  # ---------------------------------------------------------------------------

  # JWT verification — same logic as WhisprMessagingWeb.Plugs.Authenticate
  if Mix.env() == :test do
    defp verify_jwt("test_token_" <> rest) when rest != "" do
      # Format de test : "test_token_<user_id>" ou "test_token_<user_id>:<device_id>"
      case String.split(rest, ":", parts: 2) do
        [user_id, device_id] -> {:ok, user_id, device_id}
        [user_id] -> {:ok, user_id, nil}
      end
    end
  end

  defp verify_jwt(token) do
    with {:ok, kid} <- peek_kid(token),
         {:ok, pem} <- JwksCache.get_signing_key(kid),
         {:ok, claims} <- validate_token(token, pem),
         {:ok, user_id} <- extract_sub(claims) do
      device_id = extract_device_id(claims)
      {:ok, user_id, device_id}
    else
      {:error, :missing_kid} -> {:error, :missing_kid}
      {:error, :not_loaded} -> {:error, :jwks_not_loaded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_token(token, pem) do
    signer = Joken.Signer.create("ES256", %{"pem" => pem})
    Joken.verify_and_validate(token_config(), token, signer)
  end

  defp token_config do
    iss = System.get_env("JWT_ISSUER") || "whispr-auth"

    Joken.Config.default_claims(skip: [:iat, :nbf, :aud], iss: iss)
    |> Joken.Config.add_claim("aud", nil, &__MODULE__.valid_aud?/1)
  end

  # WHISPR-1239 : on impose la presence d'un `kid` dans le header JWT.
  # Sans `kid`, JwksCache devrait sinon fallback sur "premiere cle du cache",
  # ce qui devient non-deterministe pendant une rotation (Map non ordonnee).
  defp peek_kid(token) do
    with [header_b64 | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} when is_binary(kid) and kid != "" <- Jason.decode(json) do
      {:ok, kid}
    else
      _ -> {:error, :missing_kid}
    end
  end

  # Tente d'extraire le sub du payload sans verifier la signature.
  # Utilise uniquement pour enrichir les logs de rejet — jamais pour autoriser.
  defp peek_sub(token) do
    with [_, payload_b64 | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, %{"sub" => sub}} when is_binary(sub) and sub != "" <- Jason.decode(json) do
      sub
    else
      _ -> nil
    end
  end

  defp extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "", do: {:ok, sub}
  defp extract_sub(_), do: {:error, "missing or invalid sub claim"}

  # Extrait le device_id depuis les claims JWT (claim `did` ou `device_id`).
  # Nil si absent : les tokens sans claim device tombent en TOFU par user_id seul.
  defp extract_device_id(%{"did" => did}) when is_binary(did) and did != "", do: did
  defp extract_device_id(%{"device_id" => did}) when is_binary(did) and did != "", do: did
  defp extract_device_id(_), do: nil
end
