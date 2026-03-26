defmodule WhisprMessagingWeb.ConversationController do
  @moduledoc """
  REST API controller for conversation operations.
  Handles CRUD operations for conversations (direct and group).
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :index do
    get("/conversations")
    summary("List user conversations")
    description("Lists all conversations for the authenticated user with optional filtering")
    produces("application/json")

    parameter(:limit, :query, :integer, "Maximum number of conversations to return (max: 100)",
      required: false
    )

    parameter(:type, :query, :string, "Filter by conversation type",
      enum: [:direct, :group],
      required: false
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ConversationsResponse))
    response(400, "Bad Request")
  end

  @doc """
  Lists conversations for the authenticated user.
  GET /api/v1/conversations

  Query params:
  - limit: number of conversations (default: 50, max: 100)
  - type: filter by type (direct|group)
  """
  def index(conn, params) do
    user_id = conn.assigns[:user_id]

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
        meta:
          camelize_keys(%{
            count: length(conversations),
            user_id: user_id
          })
      })
    end
  end

  swagger_path :search do
    get("/conversations/search")
    summary("Search user conversations")

    description(
      "Searches the authenticated user's conversations by group name or participant user ID"
    )

    produces("application/json")
    parameter(:q, :query, :string, "Search term (name fragment or exact participant user_id)", required: true)

    parameter(:limit, :query, :integer, "Maximum number of results to return (max: 50)",
      required: false
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ConversationsResponse))
    response(400, "Bad Request - missing q parameter")
  end

  @doc """
  Searches conversations for the authenticated user.
  GET /api/v1/conversations/search?q=...

  Query params:
  - q: search term (required) — matched against group name or participant user_id
  - limit: max results (default: 20, max: 50)
  """
  def search(conn, params) do
    user_id = conn.assigns[:user_id]
    query_term = params["q"]

    cond do
      is_nil(user_id) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})

      is_nil(query_term) or String.trim(query_term) == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing required parameter: q"})

      true ->
        limit = min(String.to_integer(params["limit"] || "20"), 50)
        conversations = Conversations.search_user_conversations(user_id, query_term, limit: limit)

        json(conn, %{
          data: render_conversations(conversations),
          meta: %{
            count: length(conversations),
            query: query_term
          }
        })
    end
  end

  swagger_path :create do
    post("/conversations")
    summary("Create a new conversation")
    description("Creates a new direct or group conversation")
    produces("application/json")
    consumes("application/json")

    parameter(
      :conversation,
      :body,
      Schema.ref(:ConversationCreateRequest),
      "Conversation parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(201, "Created", Schema.ref(:ConversationResponse))
    response(400, "Bad Request")
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

  # Handle direct conversation with other_user_id (authenticated user is implied)
  defp do_create(conn, %{"type" => "direct", "other_user_id" => other_user_id} = params) do
    current_user_id = conn.assigns[:user_id]
    metadata = params["metadata"] || %{}

    if is_nil(current_user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Authentication required"})
    else
      case Conversations.create_direct_conversation(current_user_id, other_user_id, metadata) do
        {:ok, conversation} ->
          conn
          |> put_status(:created)
          |> json(%{
            data: render_conversation(conversation)
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  # Handle direct conversation with explicit user_ids list
  defp do_create(conn, %{"type" => "direct", "user_ids" => [user1_id, user2_id]} = params) do
    metadata = params["metadata"] || %{}

    case Conversations.create_direct_conversation(user1_id, user2_id, metadata) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: render_conversation(conversation)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  defp do_create(conn, %{"type" => "group"} = params) do
    user_ids = params["user_ids"] || params["member_ids"] || []
    name = params["name"]
    metadata = params["metadata"] || %{}
    external_group_id = params["external_group_id"]
    creator_id = conn.assigns[:user_id]

    if is_nil(creator_id) do
      respond_missing_creator(conn)
    else
      member_ids = Enum.filter(user_ids, fn id -> id != creator_id end)
      validate_and_create_group(conn, creator_id, member_ids, name, external_group_id, metadata)
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

  defp respond_missing_creator(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "creator_id is required for group conversations"})
  end

  defp validate_and_create_group(conn, creator_id, member_ids, name, external_group_id, metadata) do
    if length(member_ids) < 1 do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{members: ["Group must have at least 2 members (including creator)"]}})
    else
      handle_group_creation(conn, creator_id, member_ids, name, external_group_id, metadata)
    end
  end

  defp handle_group_creation(conn, creator_id, member_ids, name, external_group_id, metadata) do
    case Conversations.create_group_conversation(
           creator_id,
           member_ids,
           name,
           external_group_id,
           metadata
         ) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{data: render_conversation(conversation)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  swagger_path :show do
    get("/conversations/{id}")
    summary("Get a conversation")
    description("Retrieves a specific conversation by ID with member details")
    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ConversationDetailResponse))
    response(403, "Forbidden - User is not a member")
    response(404, "Not Found")
  end

  @doc """
  Gets a single conversation.
  GET /api/v1/conversations/:id
  """
  def show(conn, %{"id" => id}) do
    user_id = conn.assigns[:user_id]

    if user_id do
      with {:ok, conversation} <- Conversations.get_conversation_with_members(id, user_id),
           true <- user_is_member?(conversation, user_id) do
        member_info = Map.get(conversation, :member_info)

        json(conn, %{
          data: render_conversation_with_members(conversation, member_info)
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

  swagger_path :update do
    put("/conversations/{id}")
    summary("Update a conversation")
    description("Updates conversation details such as name or metadata")
    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)

    parameter(
      :conversation,
      :body,
      Schema.ref(:ConversationUpdateRequest),
      "Conversation update parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ConversationResponse))
    response(404, "Not Found")
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
    user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- member?(conversation.id, user_id) do
      # Handle metadata merging and name update
      existing_metadata = conversation.metadata || %{}
      new_metadata = conversation_params["metadata"] || %{}
      merged_metadata = Map.merge(existing_metadata, new_metadata)

      merged_metadata =
        if name = conversation_params["name"] do
          Map.put(merged_metadata, "name", name)
        else
          merged_metadata
        end

      conversation_params = Map.put(conversation_params, "metadata", merged_metadata)

      case Conversations.update_conversation(conversation, conversation_params) do
        {:ok, updated_conversation} ->
          json(conn, %{
            data: render_conversation(updated_conversation)
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: inspect(reason)})
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
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/conversations/{id}")
    summary("Delete a conversation")
    description("Deactivates a conversation (soft delete)")
    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ConversationDeleteResponse))
    response(404, "Not Found")
  end

  @doc """
  Deletes (deactivates) a conversation.
  DELETE /api/v1/conversations/:id
  """
  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- member?(conversation.id, user_id),
         {:ok, deactivated_conversation} <- Conversations.deactivate_conversation(conversation) do
      json(conn, %{
        data:
          camelize_keys(%{
            id: deactivated_conversation.id,
            is_active: deactivated_conversation.is_active,
            deleted_at: DateTime.utc_now()
          })
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

  # ---------------------------------------------------------------------------
  # Per-user conversation settings (WHISPR-467)
  # ---------------------------------------------------------------------------

  swagger_path :get_member_settings do
    get("/conversations/{id}/settings")
    summary("Get conversation settings for current user")

    description(
      "Returns the authenticated user's per-conversation settings " <>
        "(mute, notifications, custom name, etc.)."
    )

    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success")
    response(404, "Conversation not found or user not a member")
  end

  @doc """
  Returns the current user's per-conversation settings.
  GET /api/v1/conversations/:id/settings
  """
  def get_member_settings(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})
    else
      case Conversations.get_conversation_member_settings(conversation_id, user_id) do
        {:ok, settings} ->
          json(conn, %{data: %{conversation_id: conversation_id, settings: settings}})

        {:error, :not_member} ->
          conn |> put_status(:not_found) |> json(%{error: "Conversation not found"})
      end
    end
  end

  swagger_path :update_member_settings do
    put("/conversations/{id}/settings")
    summary("Update conversation settings for current user")

    description(
      "Partially updates the authenticated user's per-conversation settings. " <>
        "Only recognised keys are accepted; others are silently ignored."
    )

    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success")
    response(404, "Conversation not found or user not a member")
    response(400, "Invalid request body")
  end

  @doc """
  Partially updates the current user's per-conversation settings.
  PUT /api/v1/conversations/:id/settings
  """
  def update_member_settings(conn, %{"id" => conversation_id} = params) do
    user_id = conn.assigns[:user_id]
    attrs = params["settings"] || Map.drop(params, ["id"])

    if is_nil(user_id) do
      conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})
    else
      case Conversations.update_conversation_member_settings(conversation_id, user_id, attrs) do
        {:ok, _member} ->
          {:ok, settings} =
            Conversations.get_conversation_member_settings(conversation_id, user_id)

          maybe_broadcast_settings_updated(user_id, conversation_id, attrs, settings)
          json(conn, %{data: %{conversation_id: conversation_id, settings: settings}})

        {:error, :not_member} ->
          conn |> put_status(:not_found) |> json(%{error: "Conversation not found"})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})
      end
    end
  end

  @doc """
  Adds a member to a conversation.
  POST /api/v1/conversations/:id/members
  """
  def add_member(conn, %{"id" => id} = params) do
    member_id = params["user_id"] || params["member_id"]
    current_user_id = conn.assigns[:user_id]

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
  def remove_member(conn, %{"id" => id, "user_id" => member_id}) do
    current_user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Conversations.get_conversation(id),
         {:member_exists, {:ok, _member}} <-
           {:member_exists,
            Conversations.get_conversation_member(id, member_id)
            |> case do
              nil -> {:error, :not_found}
              member -> {:ok, member}
            end},
         true <- can_manage_members?(conversation, current_user_id),
         {:ok, _} <- Conversations.remove_conversation_member(id, member_id) do
      send_resp(conn, :no_content, "")
    else
      {:member_exists, {:error, :not_found}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Member not found"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to remove members"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      error ->
        error
    end
  end

  # Private rendering functions

  defp render_conversations(conversations) do
    Enum.map(conversations, &render_conversation/1)
  end

  defp render_conversation(conversation) do
    member_info = Map.get(conversation, :member_info)

    settings =
      if member_info do
        member_info.settings || %{}
      else
        %{}
      end

    camelize_keys(%{
      id: conversation.id,
      type: conversation.type,
      name: Map.get(conversation.metadata || %{}, "name"),
      external_group_id: conversation.external_group_id,
      metadata: conversation.metadata,
      is_active: conversation.is_active,
      is_pinned: Map.get(settings, "is_pinned", false),
      is_archived: Map.get(settings, "is_archived", false),
      is_muted: Map.get(settings, "is_muted", false),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    })
  end

  defp render_conversation_with_members(conversation, member_info) do
    base =
      conversation
      |> render_conversation()
      |> Map.put("members", Enum.map(conversation.members, &render_member/1))
      |> Map.put("memberCount", length(conversation.members))

    if member_info do
      settings = member_info.settings || %{}

      base
      |> Map.put("isMuted", Map.get(settings, "is_muted", false))
      |> Map.put("isPinned", Map.get(settings, "is_pinned", false))
      |> Map.put("isArchived", Map.get(settings, "is_archived", false))
    else
      base
    end
  end

  defp render_members(members) do
    Enum.map(members, &render_member/1)
  end

  defp maybe_broadcast_settings_updated(user_id, conversation_id, attrs, settings) do
    if Map.has_key?(attrs, "is_muted") do
      WhisprMessagingWeb.Endpoint.broadcast(
        "user:#{user_id}",
        "conversation_settings_updated",
        %{
          conversation_id: conversation_id,
          settings: settings,
          timestamp: DateTime.utc_now()
        }
      )
    end
  end

  defp render_member(member) do
    camelize_keys(%{
      user_id: member.user_id,
      role: Map.get(member.settings || %{}, "role", "member"),
      joined_at: member.joined_at,
      is_active: member.is_active
    })
  end

  defp filter_by_type(conversations, nil), do: conversations

  defp filter_by_type(conversations, type) do
    Enum.filter(conversations, fn conv -> conv.type == type end)
  end

  defp user_is_member?(conversation, user_id) do
    Enum.any?(conversation.members, fn member -> member.user_id == user_id end)
  end

  defp member?(conversation_id, user_id) do
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

      _ ->
        false
    end
  end

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      ConversationCreateRequest:
        swagger_schema do
          title("Conversation Create Request")
          description("Request body for creating a conversation")

          properties do
            type(:string, "Conversation type (direct or group)",
              required: true,
              enum: [:direct, :group]
            )

            other_user_id(:string, "Other user UUID (for direct conversations)")
            user_ids(Schema.array(:string), "List of user UUIDs to add as members")
            name(:string, "Conversation name (required for group conversations)")
            metadata(:object, "Additional metadata")

            external_group_id(
              :string,
              "External group identifier (optional, for group conversations)"
            )
          end
        end,
      ConversationUpdateRequest:
        swagger_schema do
          title("Conversation Update Request")
          description("Request body for updating a conversation")

          properties do
            name(:string, "Conversation name")
            metadata(:object, "Additional metadata")
          end
        end,
      Conversation:
        swagger_schema do
          title("Conversation")
          description("A conversation object")

          properties do
            id(:string, "Conversation UUID", format: :uuid)
            type(:string, "Conversation type (direct or group)", enum: [:direct, :group])
            name(:string, "Conversation name (from metadata)")
            external_group_id(:string, "External group identifier")
            metadata(:object, "Additional metadata")
            is_active(:boolean, "Whether the conversation is active")
            inserted_at(:string, "Creation timestamp", format: :datetime)
            updated_at(:string, "Last update timestamp", format: :datetime)
          end
        end,
      ConversationWithMembers:
        swagger_schema do
          title("Conversation with Members")
          description("A conversation object with member details")

          properties do
            id(:string, "Conversation UUID", format: :uuid)
            type(:string, "Conversation type (direct or group)", enum: [:direct, :group])
            name(:string, "Conversation name (from metadata)")
            external_group_id(:string, "External group identifier")
            metadata(:object, "Additional metadata")
            is_active(:boolean, "Whether the conversation is active")
            members(Schema.array(:ConversationMember), "List of conversation members")
            member_count(:integer, "Number of members in the conversation")
            inserted_at(:string, "Creation timestamp", format: :datetime)
            updated_at(:string, "Last update timestamp", format: :datetime)
          end
        end,
      ConversationMember:
        swagger_schema do
          title("Conversation Member")
          description("A member of a conversation")

          properties do
            user_id(:string, "User UUID", format: :uuid)
            role(:string, "Member role (e.g. member, admin)")
            joined_at(:string, "Timestamp when the member joined", format: :datetime)
            is_active(:boolean, "Whether the member is active")
          end
        end,
      ConversationsIndexMeta:
        swagger_schema do
          title("Conversations Index Meta")
          description("Metadata for conversations list response")

          properties do
            count(:integer, "Total number of conversations")
            user_id(:string, "The user ID used for the query", format: :uuid)
          end
        end,
      ConversationsResponse:
        swagger_schema do
          title("Conversations Response")
          description("Response containing a list of conversations")

          properties do
            data(Schema.array(:Conversation), "List of conversations")
            meta(Schema.ref(:ConversationsIndexMeta), "Response metadata")
          end
        end,
      ConversationResponse:
        swagger_schema do
          title("Conversation Response")
          description("Response containing a single conversation")

          properties do
            data(Schema.ref(:Conversation), "Conversation object")
          end
        end,
      ConversationDetailResponse:
        swagger_schema do
          title("Conversation Detail Response")
          description("Response containing a conversation with member details")

          properties do
            data(Schema.ref(:ConversationWithMembers), "Conversation object with members")
          end
        end,
      ConversationDeleteResult:
        swagger_schema do
          title("Conversation Delete Result")
          description("Result data from deleting a conversation")

          properties do
            id(:string, "Conversation UUID", format: :uuid)
            is_active(:boolean, "Whether the conversation is active (false after deletion)")
            deleted_at(:string, "Deletion timestamp", format: :datetime)
          end
        end,
      ConversationDeleteResponse:
        swagger_schema do
          title("Conversation Delete Response")
          description("Response after deleting a conversation")

          properties do
            data(Schema.ref(:ConversationDeleteResult), "Delete result")
          end
        end
    }
  end

  # Helper to translate Ecto changeset errors
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
