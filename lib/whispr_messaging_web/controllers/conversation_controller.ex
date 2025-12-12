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
  - user_id: user UUID (required if not authenticated)
  - limit: number of conversations (default: 50, max: 100)
  - type: filter by type (direct|group)
  """
  def index(conn, params) do
    user_id = get_current_user_id(conn, params)

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
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
  def create(conn, params) do
    conversation_params = params["conversation"] || params
    do_create(conn, conversation_params)
  end

  defp do_create(conn, %{"type" => "direct", "user_ids" => [user1_id, user2_id]} = params) do
    metadata = params["metadata"] || %{}

    with {:ok, conversation} <-
           Conversations.create_direct_conversation(user1_id, user2_id, metadata) do
      conn
      |> put_status(:created)
      |> json(%{
        data: render_conversation(conversation)
      })
    end
  end

  defp do_create(conn, %{"type" => "group"} = params) do
    user_ids = params["user_ids"] || params["member_ids"] || []
    name = params["name"]
    metadata = params["metadata"] || %{}
    external_group_id = params["external_group_id"]
    # creator_id can come from params or auth token
    creator_id = params["creator_id"] || get_current_user_id(conn, params)

    if is_nil(creator_id) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "creator_id is required for group conversations"})
    else
      # Filter creator out of member list to avoid duplication if frontend sends both
      member_ids = Enum.filter(user_ids, fn id -> id != creator_id end)

      if length(member_ids) < 1 do
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{members: ["Group must have at least 2 members (including creator)"]}})
      else
        with {:ok, conversation} <-
               Conversations.create_group_conversation(creator_id, member_ids, name, external_group_id, metadata) do
          conn
          |> put_status(:created)
          |> json(%{
            data: render_conversation(conversation)
          })
        end
      end
    end
  end

  defp do_create(conn, _params) do
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
  def show(conn, %{"id" => id} = params) do
    user_id = get_current_user_id(conn, params)

    if user_id do
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

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})
      end
    else
      # If no user_id provided, just return basic info (or 403 if we want strict privacy)
      # For now keeping legacy behavior but handling 404
      with {:ok, conversation} <- Conversations.get_conversation(id) do
        json(conn, %{
          data: render_conversation(conversation)
        })
      end
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
  def update(conn, %{"id" => id} = params) do
    conversation_params = params["conversation"] || Map.drop(params, ["id"])
    user_id = get_current_user_id(conn, params)

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- is_member?(conversation.id, user_id) do
      # Handle metadata merging and name update
      existing_metadata = conversation.metadata || %{}
      new_metadata = conversation_params["metadata"] || %{}
      merged_metadata = Map.merge(existing_metadata, new_metadata)

      merged_metadata = if name = conversation_params["name"] do
        Map.put(merged_metadata, "name", name)
      else
        merged_metadata
      end

      conversation_params = Map.put(conversation_params, "metadata", merged_metadata)

      with {:ok, updated_conversation} <-
             Conversations.update_conversation(conversation, conversation_params) do
        json(conn, %{
          data: render_conversation(updated_conversation)
        })
      end
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Unauthorized"})
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})
      error ->
        error
    end
  end

  @doc """
  Deletes (deactivates) a conversation.
  DELETE /api/v1/conversations/:id
  """
  def delete(conn, %{"id" => id} = params) do
    user_id = get_current_user_id(conn, params)

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- is_member?(conversation.id, user_id),
         {:ok, deactivated_conversation} <- Conversations.deactivate_conversation(conversation) do
      json(conn, %{
        data: %{
          id: deactivated_conversation.id,
          is_active: deactivated_conversation.is_active,
          deleted_at: DateTime.utc_now()
        }
      })
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Unauthorized"})
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})
      error ->
        error
    end
  end

  @doc """
  Adds a member to a conversation.
  POST /api/v1/conversations/:id/members
  """
  def add_member(conn, %{"id" => id} = params) do
    member_id = params["user_id"] || params["member_id"]
    current_user_id = get_current_user_id(conn, params)

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- can_manage_members?(conversation, current_user_id),
         {:ok, member} <- Conversations.add_conversation_member(id, member_id) do
      conn
      |> put_status(:created)
      |> json(%{data: render_member(member)})
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to add members"})
      error ->
        error
    end
  end

  @doc """
  Removes a member from a conversation.
  DELETE /api/v1/conversations/:id/members/:user_id
  """
  def remove_member(conn, %{"id" => id, "user_id" => member_id} = params) do
    current_user_id = get_current_user_id(conn, params)

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- can_manage_members?(conversation, current_user_id),
         {:ok, _} <- Conversations.remove_conversation_member(id, member_id) do
      send_resp(conn, :no_content, "")
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to remove members"})
      error ->
        error
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
      name: Map.get(conversation.metadata || %{}, "name"),
      external_group_id: conversation.external_group_id,
      metadata: conversation.metadata,
      is_active: conversation.is_active,
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
    Enum.map(members, &render_member/1)
  end

  defp render_member(member) do
    %{
      user_id: member.user_id,
      role: Map.get(member.settings || %{}, "role", "member"),
      joined_at: member.joined_at
    }
  end

  defp filter_by_type(conversations, nil), do: conversations

  defp filter_by_type(conversations, type) do
    Enum.filter(conversations, fn conv -> conv.type == type end)
  end

  defp user_is_member?(conversation, user_id) do
    Enum.any?(conversation.members, fn member -> member.user_id == user_id end)
  end

  defp is_member?(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      nil -> false
      _ -> true
    end
  end

  defp can_manage_members?(_conversation, nil), do: false
  defp can_manage_members?(conversation, user_id) do
    case Conversations.get_conversation_member(conversation.id, user_id) do
      %{settings: settings} ->
        role = Map.get(settings || %{}, "role", "member")
        role in ["admin", "owner"]
      _ -> false
    end
  end

  defp get_current_user_id(conn, params) do
    cond do
      conn.assigns[:user_id] -> conn.assigns[:user_id]
      user_id = extract_user_from_header(conn) -> user_id
      params["user_id"] -> params["user_id"]
      true -> nil
    end
  end

  defp extract_user_from_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer test_token_" <> user_id] -> user_id
      _ -> nil
    end
  end
end
