defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  WebSocket connection handler for user sessions.

  Handles authentication, presence tracking, and channel subscriptions.
  Validates JWT tokens using the same JWKS-based flow as the HTTP Authenticate plug.
  """

  use Phoenix.Socket
  require Logger

  alias WhisprMessaging.JwksCache

  # Channels
  channel "conversation:*", WhisprMessagingWeb.ConversationChannel
  channel "user:*", WhisprMessagingWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when token != "" do
    case verify_jwt(token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}

      {:error, reason} ->
        Logger.debug("JWT verification failed on socket",
          reason: inspect(reason),
          domain: :socket
        )

        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # WHISPR-1214 — audiences acceptées sur la socket :
  #   * `nil` : access tokens HTTP actuels (pas d'aud claim côté auth-service)
  #   * `"whispr"` : audience HTTP historique
  #   * `"ws"` : token court-vivant (60 s) émis par /tokens/ws-token
  # Toute autre valeur est rejetée. Public uniquement pour le unit test.
  @doc false
  def valid_aud?(nil), do: true
  def valid_aud?(aud) when is_binary(aud), do: aud in ["whispr", "ws"]
  def valid_aud?(_), do: false

  # JWT verification — same logic as WhisprMessagingWeb.Plugs.Authenticate
  if Mix.env() == :test do
    defp verify_jwt("test_token_" <> user_id) when user_id != "", do: {:ok, user_id}
  end

  defp verify_jwt(token) do
    with {:ok, kid} <- peek_kid(token),
         {:ok, pem} <- JwksCache.get_signing_key(kid),
         {:ok, claims} <- validate_token(token, pem),
         {:ok, user_id} <- extract_sub(claims) do
      {:ok, user_id}
    else
      {:error, :missing_kid} ->
        Logger.warning("JWT rejete : header sans kid",
          domain: :socket,
          cause: :kid_missing
        )

        {:error, :missing_kid}

      {:error, :not_loaded} ->
        Logger.warning("JWKS key not yet loaded, rejecting socket connection", domain: :socket)
        {:error, :jwks_not_loaded}

      {:error, reason} ->
        {:error, reason}
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

  defp extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "", do: {:ok, sub}
  defp extract_sub(_), do: {:error, "missing or invalid sub claim"}
end
