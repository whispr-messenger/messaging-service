defmodule WhisprMessaging.Messages do
  @moduledoc """
  The Messages context - business logic for message operations.

  Handles message creation, editing, deletion, delivery tracking,
  reactions, and all message-related operations.
  """

  import Ecto.Query, warn: false
  alias WhisprMessaging.Repo

  alias WhisprMessaging.Messages.{Message, DeliveryStatus, MessageReaction, MessageAttachment}
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember}

  require Logger

  # Message CRUD operations

  @doc """
  Creates a new message in a conversation.
  """
  def create_message(attrs \\ %{}) do
    %Message{}
    |> Message.changeset(attrs)
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
  Gets the sender ID of a message.
  """
  def get_message_sender(message_id) do
    case Repo.one(from m in Message, where: m.id == ^message_id, select: m.sender_id) do
      nil -> {:error, :not_found}
      sender_id -> {:ok, sender_id}
    end
  end

  @doc """
  Lists recent messages from a conversation.
  """
  def list_recent_messages(conversation_id, limit \\ 50, before_timestamp \\ nil) do
    Message.recent_messages_query(conversation_id, limit, before_timestamp)
    |> Repo.all()
  end

  @doc """
  Lists messages after a specific timestamp.
  """
  def list_messages_after(conversation_id, timestamp) do
    Message.messages_after_query(conversation_id, timestamp)
    |> Repo.all()
  end

  @doc """
  Lists undelivered messages for a user.
  """
  def list_undelivered_messages(user_id) do
    Message.undelivered_messages_query(user_id)
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
  Soft deletes a message.
  """
  def delete_message(message_id, user_id, delete_for_everyone \\ false) do
    with {:ok, message} <- get_message(message_id),
         :ok <- validate_delete_permissions(message, user_id),
         true <- Message.deletable?(message) do
      message
      |> Message.delete_changeset(delete_for_everyone)
      |> Repo.update()
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      false -> {:error, :not_deletable}
      error -> error
    end
  end

  @doc """
  Searches messages by metadata content.
  """
  def search_messages(conversation_id, search_term) do
    Message.search_messages_query(conversation_id, search_term)
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
    query =
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
  def get_pending_delivery_confirmations(user_id) do
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

  defp validate_edit_permissions(%Message{sender_id: sender_id}, user_id)
       when sender_id == user_id,
       do: :ok

  defp validate_edit_permissions(_message, _user_id), do: {:error, :forbidden}

  defp validate_delete_permissions(%Message{sender_id: sender_id}, user_id)
       when sender_id == user_id,
       do: :ok

  defp validate_delete_permissions(_message, _user_id), do: {:error, :forbidden}

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
    Conversations.is_conversation_member?(conversation_id, user_id)
  end
end
