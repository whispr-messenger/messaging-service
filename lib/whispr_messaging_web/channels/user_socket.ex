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
        Logger.debug("[UserSocket] JWT verification failed: #{inspect(reason)}")
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # JWT verification — same logic as WhisprMessagingWeb.Plugs.Authenticate
  if Mix.env() == :test do
    defp verify_jwt("test_token_" <> user_id) when user_id != "", do: {:ok, user_id}
  end

  defp verify_jwt(token) do
    kid = peek_kid(token)

    with {:ok, pem} <- JwksCache.get_signing_key(kid),
         {:ok, claims} <- validate_token(token, pem),
         {:ok, user_id} <- extract_sub(claims) do
      {:ok, user_id}
    else
      {:error, :not_loaded} ->
        Logger.warning("[UserSocket] JWKS key not yet loaded — rejecting connection")
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
    # iss/aud must match the values the auth-service puts in its JWTs;
    # the Joken default ("Joken") would reject every real token.
    Joken.Config.default_claims(skip: [:iat, :nbf], iss: "whispr-auth", aud: "whispr")
  end

  defp peek_kid(token) do
    with [header_b64 | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header_b64, padding: false),
         {:ok, %{"kid" => kid}} when is_binary(kid) <- Jason.decode(json) do
      kid
    else
      _ -> nil
    end
  end

  defp extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "", do: {:ok, sub}
  defp extract_sub(_), do: {:error, "missing or invalid sub claim"}
end
