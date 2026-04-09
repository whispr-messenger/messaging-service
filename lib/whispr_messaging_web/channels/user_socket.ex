defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  WebSocket connection handler for user sessions.

  Handles authentication, presence tracking, and channel subscriptions.
  """

  use Phoenix.Socket
  alias WhisprMessaging.JwksCache
  require Logger

  # Channels
  channel "conversation:*", WhisprMessagingWeb.ConversationChannel
  channel "user:*", WhisprMessagingWeb.UserChannel

  # Socket params and authentication
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    token = String.replace_prefix(token, "Bearer ", "")

    case verify_auth_token(token) do
      {:ok, user_id} ->
        socket = assign(socket, :user_id, user_id)
        {:ok, socket}

      {:error, reason} ->
        Logger.info("[UserSocket] websocket connect rejected: #{inspect(reason)}")
        :error
    end
  end

  def connect(params, _socket, _connect_info) do
    Logger.info(
      "[UserSocket] websocket connect missing token param: #{inspect(Map.keys(params))}"
    )

    :error
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  defp verify_auth_token(token) do
    case Phoenix.Token.verify(
           WhisprMessagingWeb.Endpoint,
           "user auth",
           token,
           # 24 hours
           max_age: 86_400
         ) do
      {:ok, user_id} when is_binary(user_id) ->
        {:ok, user_id}

      {:error, _reason} ->
        verify_jwt(token)
    end
  end

  defp verify_jwt(token) do
    kid = peek_kid(token)

    with {:ok, pem} <- JwksCache.get_signing_key(kid),
         {:ok, claims} <- validate_token(token, pem),
         {:ok, user_id} <- extract_sub(claims) do
      {:ok, user_id}
    else
      {:error, :not_loaded} ->
        {:error, :jwks_not_loaded}

      other ->
        {:error, {:jwt_invalid, other}}
    end
  end

  defp validate_token(token, pem) do
    signer = Joken.Signer.create("ES256", %{"pem" => pem})

    case Joken.verify_and_validate(token_config(), token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_config do
    Joken.Config.default_claims(skip: [:iat, :nbf])
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

  defp extract_sub(%{"sub" => sub}) when is_binary(sub) and sub != "" do
    {:ok, sub}
  end

  defp extract_sub(_), do: {:error, :missing_sub}
end
