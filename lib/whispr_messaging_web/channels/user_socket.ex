defmodule WhisprMessagingWeb.UserSocket do
  @moduledoc """
  WebSocket connection handler for user sessions.

  Handles authentication, presence tracking, and channel subscriptions.
  """

  use Phoenix.Socket

  # Channels
  channel "conversation:*", WhisprMessagingWeb.ConversationChannel
  channel "user:*", WhisprMessagingWeb.UserChannel

  # Socket params and authentication
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_auth_token(token) do
      {:ok, user_id} ->
        socket = assign(socket, :user_id, user_id)
        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # Token verification using Phoenix.Token
  defp verify_auth_token(token) do
    case Phoenix.Token.verify(
           WhisprMessagingWeb.Endpoint,
           "user auth",
           token,
           # 24 hours
           max_age: 86400
         ) do
      {:ok, user_id} when is_binary(user_id) ->
        {:ok, user_id}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
