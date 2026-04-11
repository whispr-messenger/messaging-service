defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  REST API controller for message operations.
  Handles CRUD operations for messages in conversations.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

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
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id) do
        messages =
          Messages.list_recent_messages(conversation_id, limit, before_timestamp, user_id)
          |> WhisprMessaging.Repo.preload([:delivery_statuses, :reply_to])

        json(conn, %{
          data: render_messages(messages),
          meta:
            camelize_keys(%{
              count: length(messages),
              conversation_id: conversation_id,
              has_more: length(messages) == limit
            })
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
    response(422, "Invalid message signature")
  end

  @doc """
  Creates a new message in a conversation.
  POST /api/v1/conversations/:id/messages
  """
  def create(conn, %{"id" => conversation_id} = params) do
    # Handle different parameter structures (nested under "message" or flat)
    message_params = params["message"] || Map.drop(params, ["id"])
    user_id = conn.assigns[:user_id]

    # Ensure conversation_id and sender_id are set
    params_with_conv =
      message_params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put_new("sender_id", user_id)
      |> resolve_ttl_seconds()

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
          meta:
            camelize_keys(%{
              conversation_id: conversation_id
            })
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

        {:error, reason}
        when reason in [
               :invalid_signature,
               :missing_signature_fields,
               :invalid_key_length,
               :invalid_signature_length,
               :invalid_signature_encoding,
               :invalid_public_key_encoding,
               :untrusted_public_key,
               :verification_error
             ] ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Invalid message signature"})

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
  Searches messages by content across all conversations the user participates in.
  GET /api/messages/search?query=...&limit=50&offset=0
  """
  def search(conn, params) do
    user_id = conn.assigns[:user_id]
    query = Map.get(params, "query", "")
    limit = params |> Map.get("limit", "50") |> to_string() |> String.to_integer() |> min(100)
    offset = params |> Map.get("offset", "0") |> to_string() |> String.to_integer()

    if String.trim(query) == "" do
      json(conn, [])
    else
      messages = Messages.search_messages_global(user_id, query, limit, offset)
      json(conn, Enum.map(messages, &render_message/1))
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
    # Get user_id from conn.assigns (set by auth middleware)
    user_id = conn.assigns[:user_id]

    # Metadata is optional
    metadata = message_params["metadata"] || %{}

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "User ID required"})
    else
      case Messages.edit_message(id, user_id, content, metadata) do
        {:ok, message} ->
          message = WhisprMessaging.Repo.preload(message, :delivery_statuses)

          json(conn, %{
            data: render_message(message),
            meta:
              camelize_keys(%{
                edited: true,
                edited_at: message.edited_at
              })
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})

        {:error, :forbidden} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Forbidden"})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Message not found"})

        {:error, reason} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/messages/{id}")
    summary("Delete a message")
    description("Deletes a message (soft delete)")
    produces("application/json")
    parameter(:id, :path, :string, "Message UUID", required: true)
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
    # Get user_id from conn.assigns
    user_id = conn.assigns[:user_id]

    delete_for_everyone =
      params["delete_for_everyone"] == "true" || params["delete_for_everyone"] == true

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "User ID required"})
    else
      with {:ok, message} <- Messages.delete_message(id, user_id, delete_for_everyone) do
        json(conn, %{
          data:
            camelize_keys(%{
              id: message.id,
              is_deleted: delete_for_everyone || message.is_deleted,
              delete_for_everyone: delete_for_everyone,
              deleted_at: message.updated_at
            })
        })
      end
    end
  end

  # Private rendering functions

  defp render_messages(messages) do
    Enum.map(messages, &render_message/1)
  end

  defp render_message(message) do
    alias WhisprMessaging.Messages.DeliveryStatus

    base = %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      content: safe_binary_content(message.content),
      message_type: message.message_type,
      metadata: message.metadata,
      reply_to_id: message.reply_to_id,
      is_edited: message.edited_at != nil,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      is_ephemeral: not is_nil(message.expires_at),
      expires_at: message.expires_at,
      sent_at: message.sent_at,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }

    result =
      case message do
        %{delivery_statuses: statuses} when is_list(statuses) ->
          Map.put(base, :delivery_status, DeliveryStatus.compute_aggregate_status(statuses))

        _ ->
          Map.put(base, :delivery_status, "sent")
      end

    result =
      case message do
        %{reply_to: %WhisprMessaging.Messages.Message{} = parent} ->
          Map.put(result, :reply_to, render_reply_context(parent))

        _ ->
          result
      end

    camelize_keys(result)
  end

  defp render_reply_context(parent_message) do
    %{
      id: parent_message.id,
      sender_id: parent_message.sender_id,
      content: parent_message.content,
      message_type: parent_message.message_type,
      is_deleted: parent_message.is_deleted
    }
  end

  # Convert ttl_seconds convenience param to an explicit expires_at timestamp.
  # If both are provided, expires_at takes precedence.
  defp resolve_ttl_seconds(%{"expires_at" => _} = params), do: params

  defp resolve_ttl_seconds(%{"ttl_seconds" => ttl} = params) when is_integer(ttl) and ttl > 0 do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    params
    |> Map.put("expires_at", expires_at)
    |> Map.delete("ttl_seconds")
  end

  defp resolve_ttl_seconds(params), do: params

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      MessageCreateRequest:
        swagger_schema do
          title("Message Create Request")
          description("Request body for creating a message")

          property(
            :message,
            Schema.new do
              properties do
                content(:string, "Message content", required: true)
                message_type(:string, "Message type")
                metadata(:object, "Additional metadata")
                reply_to_id(:string, "UUID of message being replied to")
                signature(:string, "Base64-encoded Ed25519 signature (64 bytes)")

                sender_public_key(
                  :string,
                  "Base64-encoded Ed25519 public key (32 bytes)"
                )
              end
            end,
            "Message parameters"
          )
        end,
      MessageUpdateRequest:
        swagger_schema do
          title("Message Update Request")
          description("Request body for updating a message")

          property(
            :message,
            Schema.new do
              properties do
                content(:string, "Message content")
                metadata(:object, "Additional metadata")
              end
            end,
            "Message update parameters"
          )
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

            reply_to(
              Schema.ref(:MessageReplyContext),
              "Parent message preview (present when reply_to_id is set)"
            )

            is_edited(:boolean, "Whether the message has been edited")
            edited_at(:string, "Edit timestamp")
            is_deleted(:boolean, "Whether the message is deleted")

            delivery_status(:string, "Delivery status (pending, sent, delivered, read)",
              enum: [:pending, :sent, :delivered, :read]
            )

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
            data(Schema.array(:Message), "List of messages")
          end

          property(
            :meta,
            Schema.new do
              properties do
                count(:integer, "Total number of messages returned")
                conversation_id(:string, "Conversation UUID")
                has_more(:boolean, "Whether more messages are available")
              end
            end,
            "Pagination metadata"
          )
        end,
      MessageResponse:
        swagger_schema do
          title("Message Response")
          description("Response containing a single message")

          properties do
            data(Schema.ref(:Message), "Message object")
          end

          property(
            :meta,
            Schema.new do
              properties do
                conversation_id(:string, "Conversation UUID")
              end
            end,
            "Response metadata"
          )
        end,
      MessageShowResponse:
        swagger_schema do
          title("Message Show Response")
          description("Response containing a single message without metadata")

          properties do
            data(Schema.ref(:Message), "Message object")
          end
        end,
      MessageUpdateResponse:
        swagger_schema do
          title("Message Update Response")
          description("Response after updating a message")

          properties do
            data(Schema.ref(:Message), "Updated message object")
          end

          property(
            :meta,
            Schema.new do
              properties do
                edited(:boolean, "Whether the message was edited")
                edited_at(:string, "Timestamp of the edit")
              end
            end,
            "Edit metadata"
          )
        end,
      MessageReplyContext:
        swagger_schema do
          title("Message Reply Context")
          description("Preview of the parent message for reply threading")

          properties do
            id(:string, "Parent message UUID", format: :uuid)
            sender_id(:string, "Parent message sender UUID", format: :uuid)
            content(:string, "Parent message content")
            message_type(:string, "Parent message type")
            is_deleted(:boolean, "Whether the parent message is deleted")
          end
        end,
      MessageDeleteResponse:
        swagger_schema do
          title("Message Delete Response")
          description("Response after deleting a message")

          property(
            :data,
            Schema.new do
              properties do
                id(:string, "Message UUID")
                is_deleted(:boolean, "Whether the message is deleted")
                delete_for_everyone(:boolean, "Whether the message was deleted for everyone")
                deleted_at(:string, "Deletion timestamp")
              end
            end,
            "Delete result"
          )
        end
    }
  end

  # Ensure binary content is safe for JSON encoding.
  # Content stored as BYTEA may not always be valid UTF-8.
  defp safe_binary_content(nil), do: nil

  defp safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  defp safe_binary_content(content), do: to_string(content)

  # Helper to translate Ecto changeset errors
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
