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
  """
  def create(conn, %{"id" => message_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      case Messages.pin_message(message_id, user_id) do
        {:ok, pinned_message} ->
          conn
          |> put_status(:created)
          |> json(%{data: render_pinned_message(pinned_message)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Message not found"})
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
      case Messages.unpin_message(message_id) do
        {:ok, :unpinned} ->
          json(conn, %{data: camelize_keys(%{message_id: message_id, unpinned: true})})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Pinned message not found"})
      end
    end
  end

  @doc """
  Lists pinned messages for a conversation.
  GET /api/v1/conversations/:id/pins
  """
  def index(conn, %{"id" => conversation_id}) do
    with {:ok, _conversation} <- Conversations.get_conversation(conversation_id) do
      pinned_messages = Messages.list_pinned_messages(conversation_id)

      json(conn, %{
        data: Enum.map(pinned_messages, &render_pinned_message/1),
        meta:
          camelize_keys(%{
            conversation_id: conversation_id,
            count: length(pinned_messages)
          })
      })
    end
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
            content: message.content,
            message_type: message.message_type,
            inserted_at: message.inserted_at
          })

        _ ->
          base
      end

    camelize_keys(base)
  end
end
