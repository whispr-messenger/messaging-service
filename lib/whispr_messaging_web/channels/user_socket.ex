defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  WebSocket connection handler for user sessions.

  Handles authentication, presence tracking, and channel subscriptions.
  Validates JWT tokens using the same JWKS-based flow as the HTTP Authenticate plug.
  """

  use Phoenix.Socket
  require Logger

  alias WhisprMessaging.JwksCache
  alias WhisprMessagingWeb.SocketAuth

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

  # WHISPR-1214 — see SocketAuth.valid_aud?/1 for the spec.
  @doc false
  defdelegate valid_aud?(aud), to: SocketAuth

  # JWT verification — same logic as WhisprMessagingWeb.Plugs.Authenticate
  if Mix.env() == :test do
    defp verify_jwt("test_token_" <> user_id) when user_id != "", do: {:ok, user_id}
  end

  defp verify_jwt(token) do
    case peek_kid(token) do
      nil ->
        Logger.debug("Socket JWT rejected: missing or unreadable kid header", domain: :socket)
        {:error, :missing_kid}

      kid ->
        with {:ok, pem} <- JwksCache.get_signing_key(kid),
             {:ok, claims} <- validate_token(token, pem),
             {:ok, user_id} <- extract_sub(claims) do
          {:ok, user_id}
        else
          {:error, :not_loaded} ->
            Logger.warning("JWKS key not yet loaded, rejecting socket connection",
              domain: :socket
            )

            {:error, :jwks_not_loaded}

          {:error, reason} ->
            {:error, reason}
        end
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

  defp peek_kid(token), do: SocketAuth.peek_kid(token)

  defp extract_sub(claims), do: SocketAuth.extract_sub(claims)
end
