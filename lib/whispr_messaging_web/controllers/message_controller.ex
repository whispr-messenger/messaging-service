defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  REST API controller for message operations.
  Handles CRUD operations for messages in conversations.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :index do
    get("/conversations/{id}/messages")
    summary("List conversation messages")
    description("Lists recent messages for a specific conversation with pagination")
    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)

    parameter(:limit, :query, :integer, "Maximum number of messages to return (max: 100)",
      required: false
    )

    parameter(:before, :query, :string, "Timestamp to get messages before (for pagination)",
      required: false
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:MessagesResponse))
    response(404, "Conversation Not Found")
  end

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
    user_id = get_current_user_id(conn, params)

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id) do
        messages = Messages.list_recent_messages(conversation_id, limit, before_timestamp)

        json(conn, %{
          data: render_messages(messages),
          meta: %{
            count: length(messages),
            conversation_id: conversation_id,
            has_more: length(messages) == limit
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

  swagger_path :create do
    post("/conversations/{id}/messages")
    summary("Create a new message")
    description("Creates a new message in a conversation")
    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)

    parameter(:message, :body, Schema.ref(:MessageCreateRequest), "Message parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(201, "Created", Schema.ref(:MessageResponse))
    response(404, "Conversation Not Found")
  end

  @doc """
  Creates a new message in a conversation.
  POST /api/v1/conversations/:id/messages
  """
  def create(conn, %{"id" => conversation_id} = params) do
    # Handle different parameter structures (nested under "message" or flat)
    message_params = params["message"] || Map.drop(params, ["id"])
    user_id = get_current_user_id(conn, message_params)

    # Ensure conversation_id and sender_id are set
    params_with_conv =
      message_params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put_new("sender_id", user_id)

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id),
           {:ok, message} <- Messages.create_message(params_with_conv) do
        conn
        |> put_status(:created)
        |> json(%{
          data: render_message(message),
          meta: %{
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

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  swagger_path :show do
    get("/messages/{id}")
    summary("Get a message")
    description("Retrieves a specific message by ID with relations")
    produces("application/json")
    parameter(:id, :path, :string, "Message UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:MessageResponse))
    response(404, "Not Found")
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

  swagger_path :update do
    put("/messages/{id}")
    summary("Update a message")
    description("Updates (edits) the content of a message")
    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Message UUID", required: true)

    parameter(:message, :body, Schema.ref(:MessageUpdateRequest), "Message update parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:MessageUpdateResponse))
    response(403, "Forbidden - User cannot edit this message")
    response(404, "Not Found")
  end

  @doc """
  Updates a message (edit content).
  PUT /api/v1/messages/:id
  """
  def update(conn, %{"id" => id} = params) do
    # Extract params whether they are nested or flat
    message_params = params["message"] || Map.drop(params, ["id"])

    content = message_params["content"]
    # Get user_id from params or conn.assigns (if auth middleware set it)
    user_id = get_current_user_id(conn, message_params)

    # Metadata is optional
    metadata = message_params["metadata"] || %{}

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "User ID required"})
    else
      with {:ok, message} <- Messages.edit_message(id, user_id, content, metadata) do
        json(conn, %{
          data: render_message(message),
          meta: %{
            edited: true,
            edited_at: message.edited_at
          }
        })
      end
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/messages/{id}")
    summary("Delete a message")
    description("Deletes a message (soft delete)")
    produces("application/json")
    parameter(:id, :path, :string, "Message UUID", required: true)
    parameter(:user_id, :query, :string, "User UUID", required: true)
    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:MessageDeleteResponse))
    response(403, "Forbidden - User cannot delete this message")
    response(404, "Not Found")
  end

  @doc """
  Deletes a message (soft delete).
  DELETE /api/v1/messages/:id
  """
  def delete(conn, %{"id" => id} = params) do
    # Get user_id from params or conn.assigns
    user_id = get_current_user_id(conn, params)

    delete_for_everyone =
      params["delete_for_everyone"] == "true" || params["delete_for_everyone"] == true

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "User ID required"})
    else
      with {:ok, message} <- Messages.delete_message(id, user_id, delete_for_everyone) do
        json(conn, %{
          data: %{
            id: message.id,
            is_deleted: message.is_deleted,
            delete_for_everyone: message.delete_for_everyone,
            deleted_at: message.updated_at
          }
        })
      end
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
      is_edited: message.edited_at != nil,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      sent_at: message.sent_at,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
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

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      MessageCreateRequest:
        swagger_schema do
          title("Message Create Request")
          description("Request body for creating a message")

          properties do
            message(:object, "Message parameters")
          end
        end,
      MessageUpdateRequest:
        swagger_schema do
          title("Message Update Request")
          description("Request body for updating a message")

          properties do
            message(:object, "Message update parameters")
          end
        end,
      Message:
        swagger_schema do
          title("Message")
          description("A message object")

          properties do
            id(:string, "Message UUID")
            conversation_id(:string, "Conversation UUID")
            sender_id(:string, "Sender UUID")
            content(:string, "Message content")
            message_type(:string, "Message type")
            metadata(:object, "Additional metadata")
            reply_to_id(:string, "UUID of message being replied to")
            is_edited(:boolean, "Whether the message has been edited")
            edited_at(:string, "Edit timestamp")
            is_deleted(:boolean, "Whether the message is deleted")
            sent_at(:string, "Sent timestamp")
            inserted_at(:string, "Creation timestamp")
            updated_at(:string, "Last update timestamp")
          end
        end,
      MessagesResponse:
        swagger_schema do
          title("Messages Response")
          description("Response containing a list of messages")

          properties do
            data(:array, "List of messages")
            meta(:object, "Metadata")
          end
        end,
      MessageResponse:
        swagger_schema do
          title("Message Response")
          description("Response containing a single message")

          properties do
            data(:object, "Message object")
            meta(:object, "Metadata")
          end
        end,
      MessageUpdateResponse:
        swagger_schema do
          title("Message Update Response")
          description("Response after updating a message")

          properties do
            data(:object, "Updated message object")
            meta(:object, "Metadata")
          end
        end,
      MessageDeleteResponse:
        swagger_schema do
          title("Message Delete Response")
          description("Response after deleting a message")

          properties do
            data(:object, "Delete result")
          end
        end
    }
  end
end
