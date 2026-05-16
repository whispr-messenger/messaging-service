defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  REST API controller for message operations.
  Handles CRUD operations for messages in conversations.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.ConversationServer
  alias WhisprMessaging.Events.MessagingEvents
  alias WhisprMessaging.Messages
  alias WhisprMessagingWeb.ChannelHelpers
  alias WhisprMessagingWeb.Endpoint
  alias WhisprMessagingWeb.MessageRendering

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
  - search: optional content filter; when present, returns matching messages instead of paginated history
  """
  def index(conn, %{"id" => conversation_id} = params) do
    limit = min(String.to_integer(params["limit"] || "50"), 100)
    before_timestamp = params["before"]
    search_term = params["search"]
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Messages.user_can_access_message?(conversation_id, user_id) do
        messages =
          if is_binary(search_term) and search_term != "" do
            conversation_id
            |> Messages.search_messages(search_term, user_id)
            |> Enum.take(limit)
          else
            Messages.list_recent_messages(conversation_id, limit, before_timestamp, user_id)
          end
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
        # Diffusion WebSocket sur le topic conversation + chaque topic user
        # des membres hors expéditeur (contrat WHISPR-915). Aligné sur la voie
        # WS `ConversationChannel.send_message` → `ConversationServer.broadcast_message/2`.
        broadcast_new_message(conversation_id, message)

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

  # Diffuse `new_message` sur le topic de la conversation et sur le topic `user:*`
  # de chaque membre hors expéditeur. Aligné sur le format produit par
  # `ConversationServer.broadcast_message/2` pour que les clients WebSocket reçoivent
  # exactement la même charge utile, peu importe si le message vient de la voie REST
  # ou de la voie WebSocket.
  defp broadcast_new_message(conversation_id, message) do
    serialized = ConversationServer.serialize_message(message)

    Endpoint.broadcast("conversation:#{conversation_id}", "new_message", %{
      message: serialized
    })

    # Diffuse aussi sur le canal `user:*` pour les membres hors expéditeur,
    # ce qui alimente ConversationsListScreen sans nécessiter que l'écran soit ouvert.
    members = Conversations.list_conversation_members(conversation_id)

    Enum.each(members, fn member ->
      if member.user_id != message.sender_id do
        Endpoint.broadcast("user:#{member.user_id}", "new_message", %{
          message: serialized
        })
      end
    end)

    # WHISPR-1109: publish on Redis so notification-service can bump the
    # badge counter of every recipient. The REST path never hits the
    # GenServer, so the publish has to live here too.
    MessagingEvents.publish_new_message(message, members)
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
  Searches messages via metadata.plaintext_preview across all conversations the
  user is a member of (WHISPR-1444).

  GET /messaging/api/v1/messages/search?q=<query>&conversation_id=<opt>&limit=1-50&cursor=<msg_id>

  Returns `{items, next_cursor}` with cursor pagination by (sent_at desc, id desc).
  Requires `q` to be at least 2 characters.
  """
  def search(conn, params) do
    user_id = conn.assigns[:user_id]
    query = Map.get(params, "q", "")
    limit = params |> Map.get("limit", "20") |> parse_int(20) |> min(50) |> max(1)
    cursor = Map.get(params, "cursor")
    conversation_id = Map.get(params, "conversation_id")

    cond do
      is_nil(user_id) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Unauthorized"})

      String.length(String.trim(query)) < 2 ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "query too short"})

      true ->
        opts =
          [limit: limit]
          |> maybe_put_opt(:conversation_id, conversation_id)
          |> maybe_put_opt(:cursor, cursor)

        {items, next_cursor} = Messages.search_messages_preview(user_id, query, opts)

        json(conn, %{
          items:
            Enum.map(items, fn msg ->
              %{
                id: msg.id,
                conversation_id: msg.conversation_id,
                conversation_name: msg.conversation_name,
                sender_id: msg.sender_id,
                sender_username: msg.sender_username,
                preview: build_truncated_preview(msg.plaintext_preview, query),
                sent_at: msg.sent_at
              }
            end),
          next_cursor: next_cursor
        })
    end
  end

  defp build_truncated_preview(preview, query),
    do: MessageRendering.build_truncated_preview(preview, query)

  defp maybe_put_opt(opts, key, value),
    do: MessageRendering.maybe_put_opt(opts, key, value)

  defp parse_int(value, default), do: MessageRendering.parse_int(value, default)

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

          # Diffusion WebSocket sur le topic conversation
          Endpoint.broadcast(
            "conversation:#{message.conversation_id}",
            "message_edited",
            %{message: ConversationServer.serialize_message(message)}
          )

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
        # Diffusion WebSocket sur le topic conversation (uniquement pour delete_for_everyone,
        # les soft-deletes "pour moi" ne concernent que l'utilisateur courant)
        if delete_for_everyone do
          payload =
            camelize_keys(%{
              message_id: message.id,
              conversation_id: message.conversation_id,
              delete_for_everyone: true
            })

          Endpoint.broadcast(
            "conversation:#{message.conversation_id}",
            "message_deleted",
            payload
          )

          # Fanout aussi sur le canal user:* de chaque membre pour que la suppression
          # remonte sur ConversationsListScreen meme quand la ChatScreen n est pas ouverte
          # (cas typique d un groupe ou seuls quelques membres ont l ecran de conv au premier plan).
          message.conversation_id
          |> Conversations.list_conversation_members()
          |> Enum.each(fn member ->
            Endpoint.broadcast("user:#{member.user_id}", "message_deleted", payload)
          end)
        end

        json(conn, %{
          data:
            camelize_keys(%{
              id: message.id,
              is_deleted: true,
              delete_for_everyone: delete_for_everyone,
              deleted_at: message.updated_at
            })
        })
      end
    end
  end

  @doc """
  Forwards a message to one or more conversations.
  POST /messaging/api/v1/messages/:id/forward
  Body: `{ "conversation_ids": ["<uuid>", ...] }`
  """
  def forward(conn, %{"id" => source_id} = params) do
    user_id = conn.assigns[:user_id]
    target_ids = params["conversation_ids"] || []

    cond do
      is_nil(user_id) ->
        conn |> put_status(:unauthorized) |> json(%{error: "Unauthorized"})

      not is_list(target_ids) or target_ids == [] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "conversation_ids must be a non-empty list"})

      true ->
        handle_forward_result(conn, Messages.forward_message(source_id, target_ids, user_id))
    end
  end

  defp handle_forward_result(conn, {:ok, messages}) do
    Enum.each(messages, &broadcast_forwarded/1)

    conn
    |> put_status(:created)
    |> json(%{data: Enum.map(messages, &render_message/1)})
  end

  defp handle_forward_result(conn, {:error, :not_found}),
    do: conn |> put_status(:not_found) |> json(%{error: "Message not found"})

  defp handle_forward_result(conn, {:error, :forbidden}),
    do: conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})

  defp handle_forward_result(conn, {:error, %Ecto.Changeset{} = cs}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: translate_errors(cs)})
  end

  defp handle_forward_result(conn, {:error, reason}),
    do: conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})

  defp broadcast_forwarded(message),
    do: broadcast_new_message(message.conversation_id, message)

  @doc """
  Marks a message as delivered or read for the calling user (WHISPR-1059).

  PATCH /api/messages/:id/receipt
  Body: { "status": "delivered" | "read" }

  "read" implies "delivered" — if the caller jumps straight to "read" without
  ever hitting "delivered", we set `delivered_at` on the same row so aggregate
  status computation stays consistent.

  Returns 200 with the refreshed delivery_status row. 404 if the message
  doesn't exist, 400 on an invalid status value, 403 if the caller isn't a
  member of the conversation.
  """
  def receipt(conn, %{"id" => id} = params) do
    user_id = conn.assigns[:user_id]
    status = Map.get(params, "status")

    with true <- valid_receipt_status(status),
         :ok <- ensure_receipt_user(user_id),
         {:ok, message} <- Messages.get_message_with_relations(id),
         true <-
           Messages.user_can_access_message?(message.conversation_id, user_id) || :forbidden,
         {:ok, delivery_status} <- apply_receipt(id, user_id, status) do
      # WHISPR-1109: notify notification-service so the reader's badge
      # decrements. Only the "read" transition matters for unread counts.
      if status == "read" do
        MessagingEvents.publish_message_read(message.conversation_id, user_id, id)
      end

      json(conn, %{
        data: %{
          message_id: delivery_status.message_id,
          user_id: delivery_status.user_id,
          delivered_at: delivery_status.delivered_at,
          read_at: delivery_status.read_at
        }
      })
    else
      false ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{status: "must be 'delivered' or 'read'"}})

      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{errors: %{detail: "Unauthorized"}})

      :forbidden ->
        conn
        |> put_status(:forbidden)
        |> json(%{errors: %{detail: "Not a member of the conversation"}})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Message not found"}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  defp ensure_receipt_user(user_id), do: MessageRendering.ensure_receipt_user(user_id)

  defp valid_receipt_status(status), do: MessageRendering.valid_receipt_status(status)

  defp apply_receipt(message_id, user_id, "delivered"),
    do: Messages.mark_message_delivered(message_id, user_id)

  defp apply_receipt(message_id, user_id, "read") do
    # Ensure delivered_at is populated before setting read_at — otherwise
    # `DeliveryStatus.compute_aggregate_status/1` would briefly see a row
    # that's "read but never delivered", which isn't a valid state.
    _ = Messages.mark_message_delivered(message_id, user_id)
    Messages.mark_message_read(message_id, user_id)
  end

  defp changeset_errors(changeset),
    do: ChannelHelpers.format_changeset_errors(changeset)

  # Rendering / parsing helpers are factored out into MessageRendering for
  # testability. Local thin wrappers keep call sites unchanged.

  defp render_messages(messages), do: MessageRendering.render_messages(messages)
  defp render_message(message), do: MessageRendering.render_message(message)
  defp resolve_ttl_seconds(params), do: MessageRendering.resolve_ttl_seconds(params)

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
