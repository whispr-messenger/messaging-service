defmodule WhisprMessaging.Messages do
  @moduledoc """
  The Messages context - business logic for message operations.

  Handles message creation, editing, deletion, delivery tracking,
  reactions, and all message-related operations.
  """

  import Ecto.Query, warn: false

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Events.MessagingEvents
  alias WhisprMessaging.Services.UserService

  alias WhisprMessaging.Messages.{
    DeliveryStatus,
    Message,
    MessageAttachment,
    MessageDraft,
    MessageReaction,
    MessageReshare,
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
    with :ok <- SignatureVerifier.verify(attrs),
         :ok <- validate_e2ee_policy(attrs) do
      changeset = Message.changeset(%Message{}, attrs)

      with :ok <- validate_reply_to(changeset) do
        changeset
        |> Repo.insert()
        |> case do
          {:ok, message} ->
            # Preload associations for channels
            message = Repo.preload(message, [:conversation, :reply_to])
            publish_new_message_async(message)
            {:ok, message}

          error ->
            error
        end
      end
    end
  end

  # Valide que le message respecte la politique E2EE de la conversation.
  # Conv e2ee_enabled=true  -> ciphertext obligatoire, content_format="olm_v1", pas de plaintext.
  # Conv e2ee_enabled=false -> comportement actuel, pas de contrainte supplementaire.
  # On fail-open sur erreur DB (conversation non trouvee) pour ne pas bloquer l'envoi.
  defp validate_e2ee_policy(attrs) do
    conversation_id =
      attrs[:conversation_id] || attrs["conversation_id"]

    case Conversations.get_conversation(conversation_id) do
      {:ok, %Conversation{e2ee_enabled: true}} ->
        format = attrs[:content_format] || attrs["content_format"] || "plaintext"
        ciphertext = attrs[:ciphertext] || attrs["ciphertext"]

        if format == "olm_v1" and not is_nil(ciphertext) and ciphertext != "" do
          :ok
        else
          {:error, :plaintext_not_allowed_on_e2ee_conversation}
        end

      _ ->
        # conv plaintext ou non trouvee -> pas de contrainte
        :ok
    end
  end

  # Fire-and-forget Redis publish so a slow/broken Redis never blocks the
  # message insert path. notification-service consumes this to bump
  # unread badges and push FCM notifications. The dispatcher can be
  # swapped via config (`:new_message_dispatcher`) so tests can run it
  # synchronously and avoid sandbox leaks.
  defp publish_new_message_async(%Message{} = message) do
    dispatcher =
      Application.get_env(
        :whispr_messaging,
        :new_message_dispatcher,
        &default_new_message_dispatcher/1
      )

    dispatcher.(message)
    :ok
  end

  defp default_new_message_dispatcher(%Message{conversation_id: conversation_id} = message) do
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      members = Conversations.list_conversation_members(conversation_id)

      sender_name =
        case UserService.get_display_name(message.sender_id) do
          {:ok, name} -> name
          _ -> nil
        end

      MessagingEvents.publish_new_message(message, members, sender_name: sender_name)
    end)
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
  Renvoie un message uniquement s'il est encore actif (non soft-delete).
  Sert a re-checker l'etat juste avant un broadcast lie a la lecture, pour
  eviter un badge drift cote notification-service quand un autre user a
  declenche delete_for_everyone entre le snapshot et le publish (WHISPR-1392).
  """
  def get_active_message(id) do
    case Repo.one(from m in Message, where: m.id == ^id and m.is_deleted == false) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Searches messages by content across conversations the user participates in.

  Options (WHISPR-1061):
    * `:limit` — default 50, max 100 (enforced upstream)
    * `:offset` — default 0
    * `:conversation_id` — restrict results to a single conversation
    * `:from_datetime` — only messages `sent_at >= from_datetime`
    * `:to_datetime` — only messages `sent_at <= to_datetime`
    * `:message_type` — "text" | "media" | "system"
  """
  def search_messages_global(user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    conversation_id = Keyword.get(opts, :conversation_id)
    from_dt = Keyword.get(opts, :from_datetime)
    to_dt = Keyword.get(opts, :to_datetime)
    message_type = Keyword.get(opts, :message_type)

    escaped = query |> to_string() |> String.replace(~r/[\\%_]/, "\\\\\\0")
    like_query = "%#{escaped}%"

    base =
      from(m in Message,
        join: cm in WhisprMessaging.Conversations.ConversationMember,
        on: cm.conversation_id == m.conversation_id and cm.user_id == ^user_id,
        # Exclure les conversations E2EE — le ciphertext ne doit pas etre indexe
        join: c in Conversation,
        on: c.id == m.conversation_id,
        left_join: umd in UserMessageDeletion,
        on: umd.message_id == m.id and umd.user_id == ^user_id,
        where:
          ilike(fragment("encode(?, 'escape')", m.content), ^like_query) and
            m.is_deleted == false,
        where: c.e2ee_enabled == false,
        where: is_nil(umd.id),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        offset: ^offset,
        preload: [:reply_to, :attachments, :reactions, :delivery_statuses]
      )

    base
    |> maybe_filter_conversation(conversation_id)
    |> maybe_filter_from(from_dt)
    |> maybe_filter_to(to_dt)
    |> maybe_filter_message_type(message_type)
    |> Repo.all()
  end

  defp maybe_filter_conversation(query, nil), do: query

  defp maybe_filter_conversation(query, conversation_id) do
    from(m in query, where: m.conversation_id == ^conversation_id)
  end

  defp maybe_filter_from(query, nil), do: query

  defp maybe_filter_from(query, %DateTime{} = from_dt) do
    from(m in query, where: m.inserted_at >= ^from_dt)
  end

  defp maybe_filter_to(query, nil), do: query

  defp maybe_filter_to(query, %DateTime{} = to_dt) do
    from(m in query, where: m.inserted_at <= ^to_dt)
  end

  defp maybe_filter_message_type(query, nil), do: query

  defp maybe_filter_message_type(query, type) when type in ["text", "media", "system"] do
    from(m in query, where: m.message_type == ^type)
  end

  defp maybe_filter_message_type(query, _), do: query

  @doc """
  Builds a short highlight preview around the first case-insensitive match of
  `query` in `content`. Returns `{excerpt, match_start_within_excerpt,
  match_length}` or `nil` if the match can't be located (can happen when the
  match is in a byte-encoded fragment the client decodes differently).

  Kept lightweight — we don't try to score relevance or merge multi-match
  excerpts. The client already displays the raw `content`; this is just a
  shortcut for list-view rendering.
  """
  @radius 40
  def build_match_preview(content, query) when is_binary(content) and is_binary(query) do
    trimmed = String.trim(query)

    if trimmed == "" do
      nil
    else
      case :binary.match(String.downcase(content), String.downcase(trimmed)) do
        {start, length} ->
          from = max(0, start - @radius)
          to = min(byte_size(content), start + length + @radius)
          excerpt = binary_part(content, from, to - from)
          %{excerpt: excerpt, match_start: start - from, match_length: length}

        :nomatch ->
          nil
      end
    end
  end

  def build_match_preview(_, _), do: nil

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
        # Auto-unpin the message if it was pinned
        unpin_message(message_id)

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
  has individually deleted. Retourne [] si la conversation est E2EE
  (le contenu chiffre ne doit pas etre indexe).
  """
  def search_messages(conversation_id, search_term, user_id \\ nil) do
    case Conversations.get_conversation(conversation_id) do
      {:ok, %{e2ee_enabled: true}} ->
        []

      {:ok, _conversation} ->
        Message.search_messages_query(conversation_id, search_term)
        |> exclude_user_deletions(user_id)
        |> Repo.all()

      _ ->
        []
    end
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
        Logger.debug("Delivery statuses created",
          count: count,
          message_id: message_id,
          domain: :messages
        )

        {:ok, count}

      {:error, reason} ->
        Logger.error("Failed to create delivery statuses",
          reason: inspect(reason),
          domain: :messages
        )

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
  WHISPR-1304: revert d'un `mark_message_read` pour un user donne.
  Repasse `read_at` a `nil` sur la row delivery_status correspondante.
  Renvoie `{:ok, delivery_status}` si la row existait, `{:error,
  :not_found}` sinon (rien a revert).

  N'efface volontairement pas `delivered_at` : le message a toujours
  ete livre, on remet juste son etat "lu" en "non-lu".
  """
  def mark_message_unread(message_id, user_id) do
    case Repo.one(DeliveryStatus.by_message_and_user_query(message_id, user_id)) do
      nil ->
        {:error, :not_found}

      delivery_status ->
        delivery_status
        |> DeliveryStatus.mark_unread_changeset()
        |> Repo.update()
    end
  end

  @doc """
  WHISPR-1304: marque un message comme non-lu cote DB et rewind
  `last_read_at` du conversation_member juste avant le `sent_at` du
  message, pour que `unread_count` (sent_at > last_read_at) recompte
  ce message.

  Renvoie `{:ok, message}` en cas de succes, `{:error, :not_found}`
  si le message ou le delivery_status n'existe pas.

  N'effectue PAS le broadcast - c'est a l'appelant (controller ou
  channel) de delegate a `ConversationServer.mark_unread/3` ou de
  broadcast directement, parce que le broadcast doit passer par le
  gating `read_receipts` du reader.
  """
  def mark_unread(message_id, user_id) do
    # WHISPR-1315 : on enveloppe les 2 ecritures (delivery_status + member.last_read_at)
    # dans une meme transaction. Sinon un crash entre les 2 laisse l'etat incoherent
    # (delivery_status reverte mais last_read_at toujours en avance => l'item ne
    # remonte plus en unread dans l'UI au prochain refresh).
    Repo.transaction(fn ->
      with {:ok, message} <- get_message(message_id),
           {:ok, _delivery_status} <- mark_message_unread(message_id, user_id) do
        rewind_member_last_read(message, user_id)
        message
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp rewind_member_last_read(%Message{conversation_id: conv_id, sent_at: sent_at}, user_id)
       when not is_nil(sent_at) do
    with %{is_active: true} = member <- Conversations.get_conversation_member(conv_id, user_id) do
      rewind_to = DateTime.add(sent_at, -1, :second)
      Conversations.mark_member_unread(member, rewind_to)
    end

    :ok
  end

  defp rewind_member_last_read(_message, _user_id), do: :ok

  @doc """
  WHISPR-1304: broadcast `message_unread` sur le topic conversation
  + fanout sur le canal user:* de chaque membre.

  Gate par le flag privacy `read_receipts` du reader: si le user a
  desactive ses read receipts, on skip le broadcast (mais on a deja
  ecrit l'etat en DB via `mark_unread/2`). Sur erreur transitoire
  user-service on fail-open (broadcast quand meme).
  """
  def broadcast_unread(conversation_id, user_id, message_id) do
    if read_receipts_allowed?(user_id) do
      payload =
        %{
          userId: user_id,
          messageId: message_id,
          conversationId: conversation_id,
          timestamp: DateTime.utc_now()
        }

      WhisprMessagingWeb.Endpoint.broadcast(
        "conversation:#{conversation_id}",
        "message_unread",
        payload
      )

      # On exclut le reader du fanout user:*, il recoit deja l event sur conversation:*.
      conversation_id
      |> Conversations.list_conversation_members()
      |> Enum.each(fn member ->
        if member.user_id != user_id do
          WhisprMessagingWeb.Endpoint.broadcast(
            "user:#{member.user_id}",
            "message_unread",
            payload
          )
        end
      end)
    end

    :ok
  end

  defp read_receipts_allowed?(user_id) do
    case UserService.get_privacy_settings(user_id) do
      {:ok, %{read_receipts: false}} -> false
      _ -> true
    end
  end

  @doc """
  Marks all messages in a conversation as read for a user.
  """
  def mark_conversation_read(conversation_id, user_id, timestamp \\ nil) do
    read_time = timestamp || DateTime.utc_now() |> DateTime.truncate(:second)

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
  Forwards a source message to one or more target conversations.

  The caller must be a member of the source conversation and of every
  target conversation. Returns `{:ok, messages}` where `messages` is the
  list of created messages (one per target), or `{:error, reason}` on the
  first failure.
  """
  def forward_message(source_message_id, target_conversation_ids, user_id)
      when is_list(target_conversation_ids) do
    with {:ok, source} <- get_message(source_message_id),
         true <- user_can_access_message?(source.conversation_id, user_id) || :forbidden_source do
      do_forward(source, target_conversation_ids, user_id)
    else
      :forbidden_source -> {:error, :forbidden}
      other -> other
    end
  end

  defp do_forward(%Message{} = source, target_ids, user_id) do
    target_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn target_id, acc ->
      forward_to_target(source, target_id, user_id, acc)
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp forward_to_target(source, target_id, user_id, {:ok, acc}) do
    if user_can_access_message?(target_id, user_id) do
      wrap_forward_insert(create_message(forward_attrs(source, target_id, user_id)), acc)
    else
      {:halt, {:error, :forbidden}}
    end
  end

  defp wrap_forward_insert({:ok, message}, acc), do: {:cont, {:ok, [message | acc]}}
  defp wrap_forward_insert({:error, reason}, _acc), do: {:halt, {:error, reason}}

  defp forward_attrs(source, target_id, user_id) do
    %{
      "conversation_id" => target_id,
      "sender_id" => user_id,
      "message_type" => source.message_type,
      "content" => source.content,
      "metadata" => Map.put(source.metadata || %{}, "forwarded", true),
      "client_random" => :erlang.unique_integer([:positive]) |> rem(2_147_483_647),
      "forwarded_from_id" => source.id
    }
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
  Lists pending scheduled messages for a sender, optionally scoped to a
  conversation when `conversation_id` is provided.
  """
  def list_scheduled_messages(sender_id, conversation_id \\ nil)

  def list_scheduled_messages(sender_id, nil) do
    ScheduledMessage.pending_by_sender_query(sender_id)
    |> Repo.all()
  end

  def list_scheduled_messages(sender_id, conversation_id) do
    ScheduledMessage.pending_by_sender_and_conversation_query(sender_id, conversation_id)
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

  # ──────────────────────────────────────────────────────────────────────
  # E2EE key-packet re-share
  #
  # When a new device of an existing user joins the network, every prior
  # message lacks a key_packet for it. The user's other (already trusted)
  # devices fix this by locally decrypting each message's per-message key,
  # re-encrypting it with the new device's identity_key, and POSTing the
  # opaque packet here. The server only stores the packets; it never sees
  # plaintext message content nor the per-message key.
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Bulk-upsert reshare packets produced by `resharer_device_id`.

  Each entry in `attrs_list` must include `message_id`,
  `recipient_user_id`, `recipient_device_id`, `nonce`, `box`. The
  `resharer_device_id` is taken from the authenticated caller and copied
  in here so the caller can't spoof it. `on_conflict: :nothing` makes the
  endpoint idempotent — a re-share script can run repeatedly without
  blowing up on the unique (message_id, recipient_device_id) constraint.
  """
  def insert_reshares(resharer_device_id, attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.map(fn a ->
        %{
          message_id: a["message_id"] || a[:message_id],
          recipient_user_id: a["recipient_user_id"] || a[:recipient_user_id],
          recipient_device_id: a["recipient_device_id"] || a[:recipient_device_id],
          nonce: a["nonce"] || a[:nonce],
          box: a["box"] || a[:box],
          resharer_device_id: resharer_device_id,
          resharer_identity_key: a["resharer_identity_key"] || a[:resharer_identity_key],
          inserted_at: now
        }
      end)
      |> Enum.reject(fn r ->
        is_nil(r.message_id) or is_nil(r.recipient_user_id) or
          is_nil(r.recipient_device_id) or is_nil(r.nonce) or is_nil(r.box) or
          is_nil(r.resharer_identity_key)
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          Repo.insert_all(MessageReshare, rows,
            on_conflict: :nothing,
            conflict_target: [:message_id, :recipient_device_id]
          )

        {:ok, count}
    end
  end

  @doc """
  Returns the reshare packets addressed to `device_id` for the given
  message ids. Used by the read path to splice an extra
  `reshare_key_packets` list into the envelope rendered for the
  recipient device.

  Argument order is `(message_ids, device_id)` so it composes with the
  natural pipe coming out of `messages |> Enum.map(& &1.id)`.
  """
  def list_reshares_for_device(message_ids, device_id) when is_list(message_ids) do
    case message_ids do
      [] ->
        []

      _ ->
        from(r in MessageReshare,
          where: r.recipient_device_id == ^device_id and r.message_id in ^message_ids,
          select: %{
            message_id: r.message_id,
            recipient_user_id: r.recipient_user_id,
            recipient_device_id: r.recipient_device_id,
            nonce: r.nonce,
            box: r.box,
            resharer_identity_key: r.resharer_identity_key
          }
        )
        |> Repo.all()
    end
  end
end
