defmodule WhisprMessagingWeb.ConversationController do
  @moduledoc """
  REST API controller for conversation operations.
  Handles CRUD operations for conversations (direct and group).
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Lists conversations for a user.
  GET /api/v1/conversations?user_id=uuid

  Query params:
  - user_id: user UUID (required)
  - limit: number of conversations (default: 50, max: 100)
  - type: filter by type (direct|group)
  """
  def index(conn, %{"user_id" => user_id} = params) do
    limit = min(String.to_integer(params["limit"] || "50"), 100)
    conversation_type = params["type"]

    conversations =
      user_id
      |> Conversations.list_user_conversations(limit)
      |> filter_by_type(conversation_type)

    json(conn, %{
      data: render_conversations(conversations),
      meta: %{
        count: length(conversations),
        user_id: user_id
      }
    })
  end

  @doc """
  Creates a new conversation.
  POST /api/v1/conversations

  Body for direct conversation:
  {
    "type": "direct",
    "user_ids": ["uuid1", "uuid2"],
    "metadata": {}
  }

  Body for group conversation:
  {
    "type": "group",
    "name": "Group name",
    "user_ids": ["uuid1", "uuid2", "uuid3"],
    "metadata": {},
    "external_group_id": "optional_external_id"
  }
  """
  def create(conn, %{"conversation" => %{"type" => "direct", "user_ids" => [user1_id, user2_id]} = params}) do
    metadata = params["metadata"] || %{}

    with {:ok, conversation} <- Conversations.create_direct_conversation(user1_id, user2_id, metadata) do
      conn
      |> put_status(:created)
      |> json(%{
        data: render_conversation(conversation)
      })
    end
  end

  def create(conn, %{"conversation" => %{"type" => "group"} = params}) do
    user_ids = params["user_ids"] || []
    name = params["name"]
    metadata = params["metadata"] || %{}
    external_group_id = params["external_group_id"]

    with {:ok, conversation} <- Conversations.create_group_conversation(name, user_ids, external_group_id, metadata) do
      conn
      |> put_status(:created)
      |> json(%{
        data: render_conversation(conversation)
      })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "Invalid conversation type or missing required fields",
      required: %{
        direct: ["type", "user_ids"],
        group: ["type", "name", "user_ids"]
      }
    })
  end

  @doc """
  Gets a single conversation.
  GET /api/v1/conversations/:id?user_id=uuid
  """
  def show(conn, %{"id" => id, "user_id" => user_id}) do
    with {:ok, conversation} <- Conversations.get_conversation_with_members(id),
         true <- user_is_member?(conversation, user_id) do
      json(conn, %{
        data: render_conversation_with_members(conversation)
      })
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "User is not a member of this conversation"})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, conversation} <- Conversations.get_conversation(id) do
      json(conn, %{
        data: render_conversation(conversation)
      })
    end
  end

  @doc """
  Updates a conversation.
  PUT /api/v1/conversations/:id

  Body:
  {
    "name": "New name",
    "metadata": {}
  }
  """
  def update(conn, %{"id" => id, "conversation" => conversation_params}) do
    with {:ok, conversation} <- Conversations.get_conversation(id),
         {:ok, updated_conversation} <- Conversations.update_conversation(conversation, conversation_params) do
      json(conn, %{
        data: render_conversation(updated_conversation)
      })
    end
  end

  @doc """
  Deletes (deactivates) a conversation.
  DELETE /api/v1/conversations/:id
  """
  def delete(conn, %{"id" => id}) do
    with {:ok, conversation} <- Conversations.get_conversation(id),
         {:ok, deactivated_conversation} <- Conversations.deactivate_conversation(conversation) do
      json(conn, %{
        data: %{
          id: deactivated_conversation.id,
          is_active: deactivated_conversation.is_active,
          deleted_at: DateTime.utc_now()
        }
      })
    end
  end

  # Private rendering functions

  defp render_conversations(conversations) do
    Enum.map(conversations, &render_conversation/1)
  end

  defp render_conversation(conversation) do
    %{
      id: conversation.id,
      type: conversation.type,
      name: conversation.name,
      external_group_id: conversation.external_group_id,
      metadata: conversation.metadata,
      is_active: conversation.is_active,
      last_message_at: conversation.last_message_at,
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    }
  end

  defp render_conversation_with_members(conversation) do
    conversation
    |> render_conversation()
    |> Map.put(:members, render_members(conversation.members))
    |> Map.put(:member_count, length(conversation.members))
  end

  defp render_members(members) do
    Enum.map(members, fn member ->
      %{
        user_id: member.user_id,
        role: member.role,
        joined_at: member.inserted_at
      }
    end)
  end

  defp filter_by_type(conversations, nil), do: conversations
  defp filter_by_type(conversations, type) do
    Enum.filter(conversations, fn conv -> conv.type == type end)
  end

  defp user_is_member?(conversation, user_id) do
    Enum.any?(conversation.members, fn member -> member.user_id == user_id end)
  end
end
