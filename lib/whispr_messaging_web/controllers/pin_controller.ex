defmodule WhisprMessagingWeb.PinController do
  @moduledoc """
  REST API controller for message pinning operations.
  Handles pinning, unpinning, and listing pinned messages.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Pins a message.
  POST /api/v1/messages/:id/pin
  """
  def create(conn, %{"id" => message_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, message} <- Messages.get_message(message_id),
           true <- Messages.user_can_access_message?(message.conversation_id, user_id),
           {:ok, pinned_message} <- Messages.pin_message(message_id, user_id) do
        conn
        |> put_status(:created)
        |> json(%{
          data: render_pinned_message(pinned_message)
        })
      else
        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Message not found"})

        {:error, :message_deleted} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Cannot pin a deleted message"})

        false ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Unauthorized"})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "Message is already pinned"})
      end
    end
  end

  @doc """
  Unpins a message.
  DELETE /api/v1/messages/:id/pin
  """
  def delete(conn, %{"id" => message_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, message} <- Messages.get_message(message_id),
           true <- Messages.user_can_access_message?(message.conversation_id, user_id),
           {:ok, _pinned_message} <- Messages.unpin_message(message_id) do
        json(conn, %{
          data: %{
            message_id: message_id,
            unpinned: true
          }
        })
      else
        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Pinned message not found"})

        false ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Unauthorized"})
      end
    end
  end

  @doc """
  Lists pinned messages for a conversation.
  GET /api/v1/conversations/:id/pins
  """
  def index(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id) do
        pinned_messages = Messages.list_pinned_messages(conversation_id)

        json(conn, %{
          data: Enum.map(pinned_messages, &render_pinned_message/1),
          meta: %{
            count: length(pinned_messages),
            conversation_id: conversation_id
          }
        })
      else
        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        false ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Unauthorized"})
      end
    end
  end

  # Private rendering functions

  defp render_pinned_message(pinned_message) do
    base = %{
      id: pinned_message.id,
      message_id: pinned_message.message_id,
      conversation_id: pinned_message.conversation_id,
      pinned_by: pinned_message.pinned_by,
      pinned_at: pinned_message.pinned_at,
      inserted_at: pinned_message.inserted_at,
      updated_at: pinned_message.updated_at
    }

    case pinned_message do
      %{message: %WhisprMessaging.Messages.Message{} = message} ->
        Map.put(base, :message, %{
          id: message.id,
          conversation_id: message.conversation_id,
          sender_id: message.sender_id,
          content: message.content,
          message_type: message.message_type,
          metadata: message.metadata,
          sent_at: message.sent_at,
          inserted_at: message.inserted_at
        })

      _ ->
        base
    end
  end
end
