defmodule WhisprMessaging.Messages do
  @moduledoc """
  The Messages context - business logic for message operations.

  Handles message creation, editing, deletion, delivery tracking,
  reactions, and all message-related operations.
  """

  import Ecto.Query, warn: false

  alias WhisprMessaging.Messages.{
    DeliveryStatus,
    Message,
    MessageAttachment,
    MessageDraft,
    MessageReaction,
    PinnedMessage,
    ScheduledMessage,
    SignatureVerifier,
    UserMessageDeletion
  }

  alias WhisprMessaging.Repo

  require Logger

  # Message CRUD operations

  @doc """
  Creates a new message in a conversation.

  Verifies the Ed25519 signature when `signature` and `sender_public_key`
  are present in attrs. Signature verification happens before persistence,
  and any error returned by `SignatureVerifier.verify/1` is passed through.

  Possible signature error reasons:

    * `:missing_signature_fields` — only one of signature/public_key provided
    * `:invalid_signature` — signature does not match the payload
    * `:invalid_signature_encoding` — signature is not valid Base64
    * `:invalid_public_key_encoding` — public key is not valid Base64
    * `:invalid_key_length` — public key is not 32 bytes
    * `:invalid_signature_length` — signature is not 64 bytes
    * `:verification_error` — unexpected error during crypto verification
  """
  def create_message(attrs \\ %{}) do
    # Verify signature before persisting (no DB write on failure)
    with :ok <- SignatureVerifier.verify(attrs) do
      changeset = Message.changeset(%Message{}, attrs)

      with :ok <- validate_reply_to(changeset) do
        changeset
        |> Repo.insert()
        |> case do
          {:ok, message} ->
            # Preload associations for channels
            message = Repo.preload(message, [:conversation, :reply_to])
            {:ok, message}

          error ->
            error
        end
      end
    end
  end

  @doc """
  Gets a single message by id.
  """
  def get_message(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Gets a message with all its relations.
  """
  def get_message_with_relations(id) do
    case Repo.one(Message.with_relations_query(id)) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Searches messages by content across conversations the user participates in.
  """
  def search_messages_global(user_id, query, limit \\ 50, offset \\ 0) do
    like_query = "%#{query}%"

    from(m in Message,
      join: cm in WhisprMessaging.Conversations.ConversationMember,
      on: cm.conversation_id == m.conversation_id and cm.user_id == ^user_id,
      left_join: umd in UserMessageDeletion,
      on: umd.message_id == m.id and umd.user_id == ^user_id,
      where:
        ilike(fragment("encode(?, 'escape')", m.content), ^like_query) and m.is_deleted == false,
      where: is_nil(umd.id),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      offset: ^offset,
      preload: [:reply_to, :attachments, :reactions, :delivery_statuses]
    )
    |> Repo.all()
  end

  @doc """
  Gets the sender ID of a message.
  """
  def get_message_sender(message_id) do
    case Repo.one(from m in Message, where: m.id == ^message_id, select: m.sender_id) do
      nil -> {:error, :not_found}
      sender_id -> {:ok, sender_id}
    end
  end

  @doc """
  Gets a message by sender and client_random.
  """
  def get_message_by_sender_and_random(sender_id, client_random) do
    case Repo.one(
           from m in Message,
             where: m.sender_id == ^sender_id and m.client_random == ^client_random
         ) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Lists recent messages from a conversation, excluding messages the user
  has individually deleted.
  """
  def list_recent_messages(conversation_id, limit \\ 50, before_timestamp \\ nil, user_id \\ nil) do
    Message.recent_messages_query(conversation_id, limit, before_timestamp)
    |> exclude_user_deletions(user_id)
    |> Repo.all()
  end

  @doc """
  Lists messages after a specific timestamp, excluding messages the user
  has individually deleted.
  """
  def list_messages_after(conversation_id, timestamp, user_id \\ nil) do
    Message.messages_after_query(conversation_id, timestamp)
    |> exclude_user_deletions(user_id)
    |> Repo.all()
  end

  @doc """
  Lists undelivered messages for a user, excluding messages the user
  has individually deleted.
  """
  def list_undelivered_messages(user_id) do
    Message.undelivered_messages_query(user_id)
    |> exclude_user_deletions(user_id)
    |> Repo.all()
  end

  @doc """
  Edits a message (content and metadata).
  """
  def edit_message(message_id, user_id, new_content, metadata \\ %{}) do
    with {:ok, message} <- get_message(message_id),
         :ok <- validate_edit_permissions(message, user_id),
         true <- Message.editable?(message) do
      message
      |> Message.edit_changeset(new_content, metadata)
      |> Repo.update()
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      false -> {:error, :not_editable}
      error -> error
    end
  end

  @doc """
  Deletes a message.

  When `delete_for_everyone` is `true`, the message is soft-deleted globally
  (sets `is_deleted = true`). Only the original sender may do this.

  When `delete_for_everyone` is `false` (default), the message is hidden only
  for the requesting user by inserting a row into `user_message_deletions`.
  Any conversation member may do this.
  """
  def delete_message(message_id, user_id, delete_for_everyone \\ false) do
    with {:ok, message} <- get_message(message_id),
         :ok <- validate_delete_permissions(message, user_id, delete_for_everyone),
         true <- Message.deletable?(message) do
      if delete_for_everyone do
        message
        |> Message.delete_changeset(true)
        |> Repo.update()
      else
        %UserMessageDeletion{}
        |> UserMessageDeletion.changeset(%{user_id: user_id, message_id: message_id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :message_id])
        |> case do
          {:ok, _deletion} -> {:ok, message}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :forbidden} -> {:error, :forbidden}
      false -> {:error, :not_deletable}
      error -> error
    end
  end

  @doc """
  Searches messages by metadata content, excluding messages the user
  has individually deleted.
  """
  def search_messages(conversation_id, search_term, user_id \\ nil) do
    Message.search_messages_query(conversation_id, search_term)
    |> exclude_user_deletions(user_id)
    |> Repo.all()
  end

  @doc """
  Counts unread messages for a user in a conversation.
  """
  def count_unread_messages(conversation_id, user_id, last_read_at \\ nil) do
    Message.unread_count_query(conversation_id, user_id, last_read_at)
    |> Repo.one()
  end

  # Delivery Status operations

  @doc """
  Creates delivery statuses for all conversation members except sender.
  """
  def create_delivery_statuses_for_conversation(message_id, conversation_id, sender_id) do
    # Use raw SQL for efficiency
    sql = """
    INSERT INTO delivery_statuses (id, message_id, user_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), $1::uuid, cm.user_id, NOW(), NOW()
    FROM conversation_members cm
    WHERE cm.conversation_id = $2::uuid
      AND cm.user_id != $3::uuid
      AND cm.is_active = true
    """

    # Ensure IDs are binary UUIDs if they are strings
    message_id = ensure_uuid_binary(message_id)
    conversation_id = ensure_uuid_binary(conversation_id)
    sender_id = ensure_uuid_binary(sender_id)

    case Repo.query(sql, [message_id, conversation_id, sender_id]) do
      {:ok, %{num_rows: count}} ->
        Logger.debug("Created #{count} delivery statuses for message #{message_id}")
        {:ok, count}

      {:error, reason} ->
        Logger.error("Failed to create delivery statuses: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_uuid_binary(uuid) when is_binary(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, binary} -> binary
      _ -> uuid
    end
  end

  defp ensure_uuid_binary(uuid), do: uuid

  @doc """
  Marks a message as delivered for a specific user.
  """
  def mark_message_delivered(message_id, user_id, timestamp \\ nil) do
    delivered_time = timestamp || DateTime.utc_now() |> DateTime.truncate(:second)

    case get_or_create_delivery_status(message_id, user_id) do
      {:ok, delivery_status} ->
        delivery_status
        |> DeliveryStatus.mark_delivered_changeset(delivered_time)
        |> Repo.update()

      error ->
        error
    end
  end

  @doc """
  Marks a message as read for a specific user.
  """
  def mark_message_read(message_id, user_id, timestamp \\ nil) do
    read_time = timestamp || DateTime.utc_now() |> DateTime.truncate(:second)

    case get_or_create_delivery_status(message_id, user_id) do
      {:ok, delivery_status} ->
        delivery_status
        |> DeliveryStatus.mark_read_changeset(read_time)
        |> Repo.update()

      error ->
        error
    end
  end

  @doc """
  Marks all messages in a conversation as read for a user.
  """
  def mark_conversation_read(conversation_id, user_id, timestamp \\ nil) do
    read_time = timestamp || DateTime.utc_now() |> DateTime.truncate(:second)

    # Update delivery statuses for unread messages
    _query =
      from ds in DeliveryStatus,
        join: m in Message,
        on: m.id == ds.message_id,
        where: m.conversation_id == ^conversation_id,
        where: ds.user_id == ^user_id,
        where: is_nil(ds.read_at),
        where: not is_nil(ds.delivered_at) or is_nil(ds.delivered_at)

    update_query =
      from ds in DeliveryStatus,
        join: m in Message,
        on: m.id == ds.message_id,
        where: m.conversation_id == ^conversation_id,
        where: ds.user_id == ^user_id,
        where: is_nil(ds.read_at),
        update: [
          set: [
            read_at: ^read_time,
            delivered_at: fragment("COALESCE(?, ?)", ds.delivered_at, ^read_time),
            updated_at: ^read_time
          ]
        ]

    case Repo.update_all(update_query, []) do
      {count, _} -> {:ok, count}
      error -> error
    end
  end

  @doc """
  Gets unread messages for a user.
  """
  def get_unread_messages_for_user(user_id) do
    query =
      from ds in DeliveryStatus,
        where: ds.user_id == ^user_id,
        where: not is_nil(ds.delivered_at) and is_nil(ds.read_at),
        join: m in Message,
        on: m.id == ds.message_id,
        where: m.is_deleted == false,
        select: {ds, m},
        order_by: [asc: m.sent_at]

    {:ok, Repo.all(query)}
  end

  @doc """
  Gets pending delivery confirmations for a user.
  """
  def get_pending_delivery_confirmations(_user_id) do
    # This would typically be handled by a separate tracking system
    # For now, return empty list
    {:ok, []}
  end

  @doc """
  Gets read receipt summary for a message.
  """
  def get_read_receipt_summary(message_id) do
    case Repo.one(DeliveryStatus.read_receipt_summary_query(message_id)) do
      nil -> {:ok, %{total_recipients: 0, delivered_count: 0, read_count: 0}}
      summary -> {:ok, summary}
    end
  end

  @doc """
  Computes the delivery status string for a specific message and user.

  Returns one of: "pending", "sent", "delivered", "read".
  If no delivery status record exists, returns "sent" (message was persisted).
  """
  def get_message_delivery_status(message_id, user_id) do
    case Repo.one(DeliveryStatus.by_message_and_user_query(message_id, user_id)) do
      nil -> "sent"
      delivery_status -> DeliveryStatus.compute_status(delivery_status)
    end
  end

  @doc """
  Computes the aggregate delivery status for a message across all recipients.

  Returns one of: "sent", "pending", "delivered", "read".
  """
  def get_aggregate_delivery_status(message_id) do
    statuses =
      DeliveryStatus.by_message_query(message_id)
      |> Repo.all()

    DeliveryStatus.compute_aggregate_status(statuses)
  end

  # Message Reactions

  @doc """
  Adds a reaction to a message.
  """
  def add_reaction(message_id, user_id, reaction) do
    %MessageReaction{}
    |> MessageReaction.changeset(%{
      message_id: message_id,
      user_id: user_id,
      reaction: reaction
    })
    |> Repo.insert()
  end

  @doc """
  Removes a reaction from a message.
  """
  def remove_reaction(message_id, user_id, reaction) do
    query =
      from r in MessageReaction,
        where: r.message_id == ^message_id,
        where: r.user_id == ^user_id,
        where: r.reaction == ^reaction

    case Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_count, _} -> {:ok, :deleted}
    end
  end

  @doc """
  Lists reactions for a message.
  """
  def list_message_reactions(message_id) do
    MessageReaction.by_message_query(message_id)
    |> Repo.all()
  end

  @doc """
  Gets reaction summary for a message.
  """
  def get_reaction_summary(message_id) do
    MessageReaction.reaction_summary_query(message_id)
    |> Repo.all()
    |> Enum.into(%{})
  end

  # Helper functions

  defp get_or_create_delivery_status(message_id, user_id) do
    case Repo.one(DeliveryStatus.by_message_and_user_query(message_id, user_id)) do
      nil ->
        # Create new delivery status
        DeliveryStatus.create_delivery_status(message_id, user_id)
        |> Repo.insert()

      delivery_status ->
        {:ok, delivery_status}
    end
  end

  defp validate_reply_to(changeset) do
    reply_to_id = Ecto.Changeset.get_field(changeset, :reply_to_id)
    conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

    cond do
      is_nil(reply_to_id) ->
        :ok

      is_nil(conversation_id) ->
        :ok

      true ->
        case Repo.one(from(m in Message, where: m.id == ^reply_to_id, select: m.conversation_id)) do
          nil ->
            {:error,
             Ecto.Changeset.add_error(
               changeset,
               :reply_to_id,
               "referenced message does not exist"
             )}

          ^conversation_id ->
            :ok

          _other ->
            {:error,
             Ecto.Changeset.add_error(
               changeset,
               :reply_to_id,
               "must reference a message in the same conversation"
             )}
        end
    end
  end

  # Appends a LEFT JOIN + WHERE IS NULL filter against user_message_deletions
  # so that messages the given user has individually deleted are excluded.
  # When user_id is nil the query is returned unchanged (backwards-compatible).
  defp exclude_user_deletions(query, nil), do: query

  defp exclude_user_deletions(query, user_id) do
    from m in query,
      left_join: umd in UserMessageDeletion,
      on: umd.message_id == m.id and umd.user_id == ^user_id,
      where: is_nil(umd.id)
  end

  defp validate_edit_permissions(%Message{sender_id: sender_id}, user_id)
       when sender_id == user_id,
       do: :ok

  defp validate_edit_permissions(_message, _user_id), do: {:error, :forbidden}

  # "Delete for everyone" — only the sender is allowed.
  defp validate_delete_permissions(%Message{sender_id: sender_id}, user_id, true)
       when sender_id == user_id,
       do: :ok

  defp validate_delete_permissions(_message, _user_id, true), do: {:error, :forbidden}

  # "Delete for me" — any conversation member is allowed.
  # Membership is already verified at the channel/controller layer before this
  # function is reached, so we simply permit the operation.
  defp validate_delete_permissions(_message, _user_id, false), do: :ok

  # Text message helpers

  @doc """
  Creates a text message.
  """
  def create_text_message(
        conversation_id,
        sender_id,
        encrypted_content,
        client_random,
        metadata \\ %{}
      ) do
    Message.create_text_message(
      conversation_id,
      sender_id,
      encrypted_content,
      client_random,
      metadata
    )
    |> Repo.insert()
  end

  @doc """
  Creates a media message.
  """
  def create_media_message(conversation_id, sender_id, encrypted_content, client_random, metadata) do
    Message.create_media_message(
      conversation_id,
      sender_id,
      encrypted_content,
      client_random,
      metadata
    )
    |> Repo.insert()
  end

  @doc """
  Creates a system message.
  """
  def create_system_message(conversation_id, content, metadata \\ %{}) do
    create_message(%{
      conversation_id: conversation_id,
      sender_id: "00000000-0000-0000-0000-000000000000",
      message_type: "system",
      content: content,
      metadata: metadata,
      client_random: System.unique_integer([:positive])
    })
  end

  # Attachment operations

  @doc """
  Creates a message attachment record.
  """
  def create_attachment(attrs \\ %{}) do
    %MessageAttachment{}
    |> MessageAttachment.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a single attachment by id.
  """
  def get_attachment(id) do
    case Repo.get(MessageAttachment, id) do
      nil -> {:error, :not_found}
      attachment -> {:ok, attachment}
    end
  end

  @doc """
  Deletes an attachment.
  """
  def delete_attachment(id) do
    case get_attachment(id) do
      {:ok, attachment} -> Repo.delete(attachment)
      error -> error
    end
  end

  @doc """
  Checks if a user can access messages in a conversation.
  """
  def user_can_access_message?(conversation_id, user_id) do
    alias WhisprMessaging.Conversations
    Conversations.conversation_member?(conversation_id, user_id)
  end

  # Draft operations

  @doc """
  Upserts a draft for a user in a conversation.
  Only one draft per user per conversation is allowed; calling this again
  replaces the existing draft.
  """
  def upsert_draft(conversation_id, user_id, content, metadata \\ %{}) do
    attrs = %{
      conversation_id: conversation_id,
      user_id: user_id,
      content: content,
      metadata: metadata
    }

    %MessageDraft{}
    |> MessageDraft.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        set: [content: content, metadata: metadata, updated_at: NaiveDateTime.utc_now()]
      ],
      conflict_target: [:conversation_id, :user_id],
      returning: true
    )
  end

  @doc """
  Gets the draft for a specific user in a conversation.
  Returns {:ok, draft} or {:error, :not_found}.
  """
  def get_draft(conversation_id, user_id) do
    case Repo.one(MessageDraft.by_conversation_and_user_query(conversation_id, user_id)) do
      nil -> {:error, :not_found}
      draft -> {:ok, draft}
    end
  end

  @doc """
  Deletes a draft by id, ensuring it belongs to the given user.
  """
  def delete_draft(draft_id, user_id) do
    case Repo.get(MessageDraft, draft_id) do
      nil ->
        {:error, :not_found}

      %MessageDraft{user_id: ^user_id} = draft ->
        Repo.delete(draft)

      %MessageDraft{} ->
        {:error, :forbidden}
    end
  end

  # Scheduled message operations

  @doc """
  Schedules a message to be sent at a future time.
  """
  def schedule_message(attrs \\ %{}) do
    %ScheduledMessage{}
    |> ScheduledMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists pending scheduled messages for a sender.
  """
  def list_scheduled_messages(sender_id) do
    ScheduledMessage.pending_by_sender_query(sender_id)
    |> Repo.all()
  end

  @doc """
  Gets a single scheduled message by id.
  """
  def get_scheduled_message(id) do
    case Repo.get(ScheduledMessage, id) do
      nil -> {:error, :not_found}
      sm -> {:ok, sm}
    end
  end

  @doc """
  Cancels a pending scheduled message. Only the sender can cancel.
  """
  def cancel_scheduled_message(id, user_id) do
    case Repo.get(ScheduledMessage, id) do
      nil ->
        {:error, :not_found}

      %ScheduledMessage{sender_id: ^user_id} = sm ->
        sm
        |> ScheduledMessage.cancel_changeset()
        |> Repo.update()

      %ScheduledMessage{} ->
        {:error, :forbidden}
    end
  end

  @doc """
  Updates a pending scheduled message (content, scheduled_at). Only the sender can update.
  """
  def update_scheduled_message(id, user_id, attrs) do
    case Repo.get(ScheduledMessage, id) do
      nil ->
        {:error, :not_found}

      %ScheduledMessage{sender_id: ^user_id, status: "pending"} = sm ->
        sm
        |> ScheduledMessage.changeset(attrs)
        |> Repo.update()

      %ScheduledMessage{status: status} when status != "pending" ->
        {:error, :not_pending}

      %ScheduledMessage{} ->
        {:error, :forbidden}
    end
  end

  # Attachment listing

  @doc """
  Lists attachments for a specific message.
  """
  def list_message_attachments(message_id) do
    MessageAttachment.by_message_query(message_id)
    |> Repo.all()
  end

  # Pinned messages

  @doc """
  Pins a message in its conversation.
  """
  def pin_message(message_id, user_id) do
    case get_message(message_id) do
      {:ok, message} ->
        %PinnedMessage{}
        |> PinnedMessage.changeset(%{
          message_id: message_id,
          conversation_id: message.conversation_id,
          pinned_by: user_id
        })
        |> Repo.insert()

      error ->
        error
    end
  end

  @doc """
  Unpins a message.
  """
  def unpin_message(message_id) do
    query = from p in PinnedMessage, where: p.message_id == ^message_id

    case Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_count, _} -> {:ok, :unpinned}
    end
  end

  @doc """
  Lists pinned messages for a conversation.
  """
  def list_pinned_messages(conversation_id) do
    PinnedMessage.by_conversation_query(conversation_id)
    |> Repo.all()
  end
end
