defmodule WhisprMessaging.Messages do
  @moduledoc """
  Contexte pour la gestion des messages selon la documentation system_design.md
  """

  import Ecto.Query, warn: false
  alias WhisprMessaging.Repo
  
  require Logger

  alias WhisprMessaging.Messages.{
    Message, 
    DeliveryStatus, 
    MessageReaction, 
    MessageAttachment, 
    PinnedMessage,
    ScheduledMessage
  }
  # alias WhisprMessaging.Conversations (non utilisé actuellement)

  ## Messages

  @doc """
  Récupère les messages d'une conversation avec pagination
  """
  def list_conversation_messages(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_timestamp = Keyword.get(opts, :before)
    
    Message.get_recent_messages(conversation_id, limit, before_timestamp)
  end

  @doc """
  Récupère un message par son ID
  """
  def get_message!(id) do
    Message
    |> Repo.get!(id)
    |> Repo.preload([:delivery_statuses, :reactions, :attachments])
  end

  @doc """
  Crée un nouveau message
  """
  def create_message(attrs) do
    result = 
      attrs
      |> Message.create_changeset()
      |> Repo.insert()
    
    case result do
      {:ok, message} ->
        # Créer les statuts de livraison pour tous les membres de la conversation
        create_delivery_statuses_for_message(message)
        
        # Mettre à jour le timestamp de la conversation
        update_conversation_timestamp(message.conversation_id)
        
        # Précharger les associations
        message = Repo.preload(message, [:delivery_statuses, :reactions, :attachments])
        
        # Broadcaster le message en temps réel
        broadcast_new_message(message)
        
        {:ok, message}
        
      error ->
        error
    end
  end

  @doc """
  Met à jour un message (édition)
  """
  def update_message(%Message{} = message, new_content, metadata \\ %{}) do
    message
    |> Message.edit_changeset(new_content, metadata)
    |> Repo.update()
  end

  @doc """
  Supprime un message
  """
  def delete_message(%Message{} = message, delete_for_everyone \\ false) do
    message
    |> Message.delete_changeset(delete_for_everyone)
    |> Repo.update()
  end

  @doc """
  Marque un message comme lu pour un utilisateur
  """
  def mark_message_as_read(message_id, user_id) do
    Message.mark_as_read(message_id, user_id)
  end

  @doc """
  Compte les messages non lus dans une conversation
  """
  def count_unread_messages(conversation_id, user_id) do
    Message.count_unread_messages(conversation_id, user_id)
  end

  ## Delivery Status

  @doc """
  Marque un message comme livré pour un utilisateur
  """
  def mark_message_as_delivered(message_id, user_id) do
    DeliveryStatus.delivered_changeset(message_id, user_id)
    |> Repo.insert(
      on_conflict: [set: [delivered_at: DateTime.utc_now()]],
      conflict_target: [:message_id, :user_id]
    )
  end

  @doc """
  Récupère les statuts de livraison d'un message
  """
  def get_message_delivery_status(message_id) do
    from(ds in DeliveryStatus,
      where: ds.message_id == ^message_id,
      order_by: [asc: ds.delivered_at]
    )
    |> Repo.all()
  end

  ## Reactions

  @doc """
  Ajoute une réaction à un message
  """
  def add_reaction_to_message(message_id, user_id, reaction) do
    # Normaliser la réaction
    case MessageReaction.normalize_reaction(reaction) do
      {:error, :invalid_reaction} ->
        {:error, :invalid_reaction}
        
      normalized_reaction ->
        MessageReaction.add_reaction_changeset(message_id, user_id, normalized_reaction)
        |> Repo.insert()
    end
  end

  @doc """
  Retire une réaction d'un message
  """
  def remove_reaction_from_message(message_id, user_id, reaction) do
    case MessageReaction.normalize_reaction(reaction) do
      {:error, :invalid_reaction} ->
        {:error, :invalid_reaction}
        
      normalized_reaction ->
        from(mr in MessageReaction,
          where: mr.message_id == ^message_id and 
                 mr.user_id == ^user_id and 
                 mr.reaction == ^normalized_reaction
        )
        |> Repo.delete_all()
        
        :ok
    end
  end

  @doc """
  Récupère toutes les réactions d'un message
  """
  def list_message_reactions(message_id) do
    from(mr in MessageReaction,
      where: mr.message_id == ^message_id,
      order_by: [asc: mr.created_at]
    )
    |> Repo.all()
  end

  ## Attachments

  @doc """
  Ajoute une pièce jointe à un message
  """
  def add_attachment_to_message(message_id, media_id, media_type, metadata \\ %{}) do
    MessageAttachment.create_changeset(message_id, media_id, media_type, metadata)
    |> Repo.insert()
  end

  @doc """
  Récupère les pièces jointes d'un message
  """
  def list_message_attachments(message_id) do
    from(ma in MessageAttachment,
      where: ma.message_id == ^message_id,
      order_by: [asc: ma.created_at]
    )
    |> Repo.all()
  end

  ## Pinned Messages

  @doc """
  Épingle un message dans une conversation
  """
  def pin_message(conversation_id, message_id, pinned_by_user_id) do
    PinnedMessage.pin_message_changeset(conversation_id, message_id, pinned_by_user_id)
    |> Repo.insert()
  end

  @doc """
  Désépingle un message
  """
  def unpin_message(conversation_id, message_id) do
    from(pm in PinnedMessage,
      where: pm.conversation_id == ^conversation_id and pm.message_id == ^message_id
    )
    |> Repo.delete_all()
    
    :ok
  end

  @doc """
  Liste les messages épinglés d'une conversation
  """
  def list_pinned_messages(conversation_id) do
    from(pm in PinnedMessage,
      where: pm.conversation_id == ^conversation_id,
      join: m in Message, on: pm.message_id == m.id,
      where: not m.is_deleted,
      order_by: [desc: pm.pinned_at],
      preload: [message: [:reactions, :attachments]]
    )
    |> Repo.all()
  end

  ## Scheduled Messages

  @doc """
  Crée un message programmé
  """
  def create_scheduled_message(attrs) do
    ScheduledMessage.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Récupère les messages programmés prêts à être envoyés
  """
  def get_ready_scheduled_messages(limit \\ 100) do
    ScheduledMessage.get_ready_to_send(limit)
  end

  @doc """
  Marque un message programmé comme envoyé
  """
  def mark_scheduled_message_as_sent(%ScheduledMessage{} = scheduled_message) do
    scheduled_message
    |> ScheduledMessage.mark_sent_changeset()
    |> Repo.update()
  end

  @doc """
  Annule un message programmé
  """
  def cancel_scheduled_message(%ScheduledMessage{} = scheduled_message) do
    scheduled_message
    |> ScheduledMessage.cancel_changeset()
    |> Repo.update()
  end

  @doc """
  Récupère les messages programmés d'un utilisateur
  """
  def list_user_scheduled_messages(user_id, include_sent \\ false) do
    ScheduledMessage.get_user_scheduled_messages(user_id, include_sent)
  end

  ## Additional functions for metrics and compatibility

  @doc """
  Compte les messages envoyés depuis une date
  """
  def count_messages_since(since_datetime) do
    from(m in Message,
      where: m.sent_at > ^since_datetime and not m.is_deleted,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Calcule la taille moyenne des messages
  """
  def get_average_message_size do
    from(m in Message,
      where: not m.is_deleted,
      select: avg(fragment("octet_length(?)", m.content))
    )
    |> Repo.one()
    |> case do
      nil -> 0
      avg -> trunc(avg)
    end
  end

  @doc """
  Marque les messages comme expirés selon la politique de rétention
  """
  def mark_messages_as_expired(conversation_id, cutoff_date) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and 
             m.sent_at < ^cutoff_date and 
             not m.is_deleted
    )
    |> Repo.update_all(set: [is_deleted: true, delete_for_everyone: true])
  end

  @doc """
  Crée une pièce jointe pour un message
  """
  def create_message_attachment(attrs) do
    MessageAttachment.create_changeset(
      attrs["message_id"],
      attrs["media_id"], 
      attrs["media_type"],
      attrs["metadata"] || %{}
    )
    |> Repo.insert()
  end

  @doc """
  Compte le nombre de messages dans une conversation
  """
  def get_message_count_for_conversation(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id and not m.is_deleted,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Compte les messages non lus pour un utilisateur dans une conversation
  """
  def get_unread_count_for_user(conversation_id, user_id) do
    count_unread_messages(conversation_id, user_id)
  end

  @doc """
  Traite les messages programmés (à appeler périodiquement)
  """
  def process_scheduled_messages do
    ready_messages = get_ready_scheduled_messages()
    
    Enum.each(ready_messages, fn scheduled_msg ->
      # Convertir le message programmé en message normal
      message_attrs = %{
        conversation_id: scheduled_msg.conversation_id,
        sender_id: scheduled_msg.sender_id,
        message_type: scheduled_msg.message_type,
        content: scheduled_msg.content,
        metadata: scheduled_msg.metadata,
        client_random: :rand.uniform(1_000_000_000),  # Générer un random
        sent_at: DateTime.utc_now()
      }
      
      case create_message(message_attrs) do
        {:ok, _message} ->
          mark_scheduled_message_as_sent(scheduled_msg)
          
        {:error, _changeset} ->
          # Log l'erreur mais continue le traitement
          :ok
      end
    end)
    
    length(ready_messages)
  end

  ## Private Functions

  defp create_delivery_statuses_for_message(%Message{} = message) do
    # Récupérer tous les membres actifs de la conversation (sauf l'expéditeur)
    members = from(cm in WhisprMessaging.Conversations.ConversationMember,
      where: cm.conversation_id == ^message.conversation_id and 
             cm.is_active == true and 
             cm.user_id != ^message.sender_id,
      select: cm.user_id
    ) |> Repo.all()
    
    # Créer les statuts de livraison pour tous les membres
    delivery_statuses = Enum.map(members, fn user_id ->
      %{
        message_id: message.id,
        user_id: user_id,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    end)
    
    if length(delivery_statuses) > 0 do
      Repo.insert_all(DeliveryStatus, delivery_statuses)
    end
    
    :ok
  end

  defp update_conversation_timestamp(conversation_id) do
    now = DateTime.utc_now()
    
    from(c in WhisprMessaging.Conversations.Conversation,
      where: c.id == ^conversation_id
    )
    |> Repo.update_all(set: [updated_at: now])
    
    :ok
  end

  ## Broadcasting Functions

  defp broadcast_new_message(%Message{} = message) do
    # Broadcaster le message à tous les membres de la conversation
    Phoenix.PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{message.conversation_id}:messages",
      {:new_message, message}
    )
    
    # Notifier les utilisateurs individuellement pour les notifications
    broadcast_to_conversation_members(message)
  end

  defp broadcast_to_conversation_members(%Message{} = message) do
    # Récupérer tous les membres actifs de la conversation (sauf l'expéditeur)
    members = from(cm in WhisprMessaging.Conversations.ConversationMember,
      where: cm.conversation_id == ^message.conversation_id and 
             cm.is_active == true and 
             cm.user_id != ^message.sender_id,
      select: cm.user_id
    ) |> Repo.all()
    
    # Notifier chaque membre individuellement via PubSub
    Enum.each(members, fn user_id ->
      Phoenix.PubSub.broadcast(
        WhisprMessaging.PubSub,
        "user:#{user_id}:messages",
        {:new_message, message}
      )
    end)
    
    # Envoyer des notifications push via notification-service
    if not Enum.empty?(members) do
      send_push_notification(message, members)
    end
  end

  defp send_push_notification(%Message{} = message, recipient_ids) do
    # Générer un aperçu sécurisé du message
    preview = generate_secure_preview(message)
    
    # Envoyer la notification via gRPC de manière asynchrone
    Task.start(fn ->
      case WhisprMessaging.Grpc.NotificationServiceClient.send_message_notification(
        message.id,
        message.conversation_id,
        message.sender_id,
        recipient_ids,
        message_type: message.message_type,
        preview_text: preview,
        metadata: %{
          "sent_at" => DateTime.to_iso8601(message.sent_at),
          "has_attachments" => not Enum.empty?(message.attachments || [])
        },
        priority: determine_notification_priority(message)
      ) do
        {:ok, result} ->
          Logger.info("Push notification sent successfully", %{
            message_id: message.id,
            notification_id: result.notification_id,
            recipients_count: length(recipient_ids)
          })
          
        {:error, reason} ->
          Logger.error("Failed to send push notification", %{
            message_id: message.id,
            error: reason,
            recipients_count: length(recipient_ids)
          })
      end
    end)
  end

  defp generate_secure_preview(%Message{message_type: "text"}) do
    "Nouveau message"
  end
  
  defp generate_secure_preview(%Message{message_type: "media"}) do
    "Média partagé"
  end
  
  defp generate_secure_preview(%Message{message_type: "system"}) do
    "Notification système"
  end
  
  defp generate_secure_preview(_message) do
    "Nouveau message"
  end

  defp determine_notification_priority(%Message{metadata: metadata}) do
    case metadata["priority"] do
      "urgent" -> :urgent
      "high" -> :high
      "low" -> :low
      _ -> :normal
    end
  end
end
