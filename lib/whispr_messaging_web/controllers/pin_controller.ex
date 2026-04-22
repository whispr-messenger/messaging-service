defmodule WhisprMessagingWeb.PinController do
  @moduledoc """
  REST API controller for message pin operations.
  Handles pinning, unpinning, and listing pinned messages.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Pins a message.
  POST /api/v1/messages/:id/pin

  Only members of the conversation can pin messages in it.
  """
  def create(conn, %{"id" => message_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      unauthorized(conn)
    else
      with {:ok, message} <- Messages.get_message(message_id),
           true <-
             Messages.user_can_access_message?(message.conversation_id, user_id) || :forbidden,
           {:ok, pinned_message} <- Messages.pin_message(message_id, user_id) do
        conn
        |> put_status(:created)
        |> json(%{data: render_pinned_message(pinned_message)})
      else
        :forbidden ->
          conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{error: "Message not found"})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Unpins a message.
  DELETE /api/v1/messages/:id/pin

  Only members of the conversation can unpin messages.
  """
  def delete(conn, %{"id" => message_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      unauthorized(conn)
    else
      with {:ok, message} <- Messages.get_message(message_id),
           true <-
             Messages.user_can_access_message?(message.conversation_id, user_id) || :forbidden,
           {:ok, :unpinned} <- Messages.unpin_message(message_id) do
        json(conn, %{data: camelize_keys(%{message_id: message_id, unpinned: true})})
      else
        :forbidden ->
          conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{error: "Pinned message not found"})
      end
    end
  end

  @doc """
  Lists pinned messages for a conversation.
  GET /api/v1/conversations/:id/pins

  Only members of the conversation can list its pinned messages.
  """
  def index(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      unauthorized(conn)
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id) || :forbidden do
        pinned_messages = Messages.list_pinned_messages(conversation_id)

        json(conn, %{
          data: Enum.map(pinned_messages, &render_pinned_message/1),
          meta:
            camelize_keys(%{
              conversation_id: conversation_id,
              count: length(pinned_messages)
            })
        })
      else
        :forbidden ->
          conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{error: "Conversation not found"})
      end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Unauthorized"})
  end

  defp render_pinned_message(pinned_message) do
    base = %{
      id: pinned_message.id,
      message_id: pinned_message.message_id,
      conversation_id: pinned_message.conversation_id,
      pinned_by: pinned_message.pinned_by,
      pinned_at: pinned_message.pinned_at,
      inserted_at: pinned_message.inserted_at
    }

    base =
      case pinned_message do
        %{message: %WhisprMessaging.Messages.Message{} = message} ->
          Map.put(base, :message, %{
            id: message.id,
            sender_id: message.sender_id,
            content: safe_binary_content(message.content),
            message_type: message.message_type,
            inserted_at: message.inserted_at
          })

        _ ->
          base
      end

    camelize_keys(base)
  end

  defp safe_binary_content(nil), do: nil

  defp safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  defp safe_binary_content(content), do: to_string(content)
end
