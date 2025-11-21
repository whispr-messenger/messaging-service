defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  REST API controller for message operations.
  Handles CRUD operations for messages in conversations.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages
  alias WhisprMessaging.Conversations

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Lists messages for a conversation.
  GET /api/v1/conversations/:id/messages

  Query params:
  - limit: number of messages to return (default: 50, max: 100)
  - before: timestamp to get messages before (pagination)
  """
  def index(conn, %{"id" => conversation_id} = params) do
    limit = min(String.to_integer(params["limit"] || "50"), 100)
    before_timestamp = params["before"]

    with {:ok, _conversation} <- Conversations.get_conversation(conversation_id) do
      messages = Messages.list_recent_messages(conversation_id, limit, before_timestamp)

      json(conn, %{
        data: render_messages(messages),
        meta: %{
          count: length(messages),
          conversation_id: conversation_id,
          has_more: length(messages) == limit
        }
      })
    end
  end

  @doc """
  Creates a new message in a conversation.
  POST /api/v1/conversations/:id/messages

  Body:
  {
    "content": "message text",
    "sender_id": "uuid",
    "message_type": "text|image|file",
    "metadata": {},
    "reply_to_id": "uuid" (optional)
  }
  """
  def create(conn, %{"id" => conversation_id, "message" => message_params}) do
    params = Map.put(message_params, "conversation_id", conversation_id)

    with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
         {:ok, message} <- Messages.create_message(params) do
      conn
      |> put_status(:created)
      |> json(%{
        data: render_message(message),
        meta: %{
          conversation_id: conversation_id
        }
      })
    end
  end

  @doc """
  Gets a single message by ID.
  GET /api/v1/messages/:id
  """
  def show(conn, %{"id" => id}) do
    with {:ok, message} <- Messages.get_message_with_relations(id) do
      json(conn, %{
        data: render_message(message)
      })
    end
  end

  @doc """
  Updates a message (edit content).
  PUT /api/v1/messages/:id

  Body:
  {
    "content": "updated text",
    "user_id": "uuid"
  }
  """
  def update(conn, %{"id" => id, "message" => %{"content" => content, "user_id" => user_id}}) do
    with {:ok, message} <- Messages.edit_message(id, user_id, content) do
      json(conn, %{
        data: render_message(message),
        meta: %{
          edited: true,
          edited_at: message.edited_at
        }
      })
    end
  end

  @doc """
  Deletes a message (soft delete).
  DELETE /api/v1/messages/:id?user_id=uuid
  """
  def delete(conn, %{"id" => id, "user_id" => user_id}) do
    with {:ok, message} <- Messages.delete_message(id, user_id) do
      json(conn, %{
        data: %{
          id: message.id,
          deleted: true,
          deleted_at: message.deleted_at
        }
      })
    end
  end

  # Private rendering functions

  defp render_messages(messages) do
    Enum.map(messages, &render_message/1)
  end

  defp render_message(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      content: message.content,
      message_type: message.message_type,
      metadata: message.metadata,
      reply_to_id: message.reply_to_id,
      is_edited: message.is_edited,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      deleted_at: message.deleted_at,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end
end
