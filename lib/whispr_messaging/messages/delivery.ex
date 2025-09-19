defmodule WhisprMessaging.Messages.Delivery do
  @moduledoc """
  Module de livraison et distribution des messages selon system_design.md
  Gère l'envoi en temps réel, les notifications push et les accusés de réception.
  """
  
  require Logger
  import Ecto.Query
  
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.DeliveryStatus
  alias WhisprMessaging.Grpc.NotificationServiceClient
  alias WhisprMessaging.Cache.RedisConnection
  alias WhisprMessagingWeb.{ConversationChannel, UserChannel}
  
  @doc """
  Livre un message à tous les participants d'une conversation
  """
  def deliver_message(%Message{} = message) do
    Logger.info("Delivering message #{message.id} to conversation #{message.conversation_id}")
    
    # Diffusion temps réel via WebSocket
    broadcast_to_conversation(message)
    
    # Mise à jour des indicateurs de présence  
    update_presence_indicators(message)
    
    # Notifications push pour utilisateurs hors-ligne
    send_push_notifications(message)
    
    # Mise à jour des compteurs non lus
    update_unread_counters(message)
    
    {:ok, message}
  end

  @doc """
  Marque un message comme livré pour un utilisateur
  """
  def mark_as_delivered(message_id, user_id) do
    timestamp = DateTime.utc_now()
    
    # Stocker l'accusé de livraison
    store_delivery_receipt(message_id, user_id, :delivered, timestamp)
    
    # Notifier l'expéditeur
    notify_sender_of_delivery(message_id, user_id, :delivered)
    
    {:ok, :delivered}
  end

  @doc """
  Marque un message comme lu pour un utilisateur
  """
  def mark_as_read(message_id, user_id) do
    timestamp = DateTime.utc_now()
    
    # Stocker l'accusé de lecture
    store_delivery_receipt(message_id, user_id, :read, timestamp)
    
    # Mettre à jour le dernier message lu
    update_last_read_message(message_id, user_id)
    
    # Notifier l'expéditeur
    notify_sender_of_delivery(message_id, user_id, :read)
    
    {:ok, :read}
  end

  @doc """
  Récupère les statistiques de livraison d'un message
  """
  def get_delivery_stats(message_id) do
    delivered_count = count_delivery_receipts(message_id, :delivered)
    read_count = count_delivery_receipts(message_id, :read)
    
    %{
      delivered: delivered_count,
      read: read_count,
      total_recipients: get_total_recipients(message_id)
    }
  end

  @doc """
  Gère les messages programmés (envoi différé)
  """
  def schedule_message(message_attrs, scheduled_at) do
    # Stocker le message en mode draft
    message_attrs = Map.put(message_attrs, :status, :scheduled)
    
    case Messages.create_message(message_attrs) do
      {:ok, message} ->
        # Programmer la livraison
        schedule_delivery(message, scheduled_at)
        {:ok, message}
        
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Traite les messages programmés arrivés à échéance
  """
  def process_scheduled_messages do
    now = DateTime.utc_now()
    
    scheduled_messages = get_scheduled_messages_due(now)
    
    processed_count = 
      Enum.reduce(scheduled_messages, 0, fn message, acc ->
        case deliver_scheduled_message(message) do
          {:ok, _} -> acc + 1
          {:error, reason} -> 
            Logger.warning("Failed to deliver scheduled message #{message.id}: #{inspect(reason)}")
            acc
        end
      end)
    
    Logger.debug("Processed #{processed_count} scheduled messages")
    processed_count
  end

  ## Fonctions privées

  defp broadcast_to_conversation(message) do
    try do
      # Diffusion via Phoenix Channels
      ConversationChannel.broadcast_new_message(message)
      
      # Notifier les channels utilisateur des participants
      broadcast_to_participants(message)
    rescue
      error ->
        Logger.error("Failed to broadcast message: #{inspect(error)}")
    end
  end

  defp broadcast_to_participants(message) do
    # Récupérer les participants de la conversation
    participants = get_conversation_participants(message.conversation_id)
    
    Enum.each(participants, fn participant ->
      UserChannel.notify_new_message(participant.user_id, message)
    end)
  end

  defp update_presence_indicators(message) do
    try do
      # Mettre à jour les indicateurs "en train d'écrire"
      clear_typing_indicators(message.conversation_id, message.sender_id)
      
      # Mettre à jour l'activité de la conversation
      update_conversation_activity(message.conversation_id)
    rescue
      error ->
        Logger.warning("Failed to update presence indicators: #{inspect(error)}")
    end
  end

  defp send_push_notifications(message) do
    try do
      # Identifier les utilisateurs hors-ligne
      offline_users = get_offline_participants(message.conversation_id)
      
      # Envoyer les notifications push
      Enum.each(offline_users, fn user ->
        NotificationServiceClient.send_message_notification(user.id, message)
      end)
    rescue
      error ->
        Logger.error("Failed to send push notifications: #{inspect(error)}")
    end
  end

  defp update_unread_counters(message) do
    try do
      # Incrémenter les compteurs non lus pour tous les participants sauf l'expéditeur
      participants = get_conversation_participants(message.conversation_id)
      
      Enum.each(participants, fn participant ->
        unless participant.user_id == message.sender_id do
          increment_unread_count(participant.user_id, message.conversation_id)
        end
      end)
    rescue
      error ->
        Logger.warning("Failed to update unread counters: #{inspect(error)}")
    end
  end

  defp store_delivery_receipt(message_id, user_id, status, timestamp) do
    try do
      key = "delivery:#{message_id}:#{user_id}"
      
      receipt = %{
        status: status,
        timestamp: timestamp,
        user_id: user_id,
        message_id: message_id
      }
      
      RedisConnection.execute_command(:main_pool, "SET", [key, Jason.encode!(receipt)])
      RedisConnection.execute_command(:main_pool, "EXPIRE", [key, "2592000"]) # 30 jours
    rescue
      error ->
        Logger.warning("Failed to store delivery receipt: #{inspect(error)}")
    end
  end

  defp notify_sender_of_delivery(message_id, user_id, status) do
    try do
      # Récupérer le message pour connaître l'expéditeur
      message = Messages.get_message!(message_id)
      
      # Notifier l'expéditeur via WebSocket
      UserChannel.notify_delivery_status(message.sender_id, %{
        message_id: message_id,
        user_id: user_id,
        status: status,
        timestamp: DateTime.utc_now()
      })
    rescue
      error ->
        Logger.warning("Failed to notify sender of delivery: #{inspect(error)}")
    end
  end

  defp schedule_delivery(message, scheduled_at) do
    try do
      # Programmer dans Redis avec TTL
      delay_seconds = DateTime.diff(scheduled_at, DateTime.utc_now())
      
      if delay_seconds > 0 do
        key = "scheduled:#{message.id}"
        RedisConnection.execute_command(:main_pool, "SET", [key, message.id])
        RedisConnection.execute_command(:main_pool, "EXPIRE", [key, delay_seconds])
      end
    rescue
      error ->
        Logger.error("Failed to schedule delivery: #{inspect(error)}")
    end
  end

  # Placeholder functions - à implémenter selon les modèles existants
  defp get_conversation_participants(_conversation_id), do: []
  defp clear_typing_indicators(_conversation_id, _user_id), do: :ok
  defp update_conversation_activity(_conversation_id), do: :ok
  defp get_offline_participants(_conversation_id), do: []
  defp increment_unread_count(_user_id, _conversation_id), do: :ok
  defp update_last_read_message(_message_id, _user_id), do: :ok
  defp count_delivery_receipts(_message_id, _status), do: 0
  defp get_total_recipients(_message_id), do: 0
  defp get_scheduled_messages_due(_datetime), do: []
  defp deliver_scheduled_message(message) do
    try do
      # Vérifier que le message est prêt à être livré
      case validate_scheduled_message(message) do
        :ok ->
          # Livrer le message via les canaux normaux
          case deliver_message_to_participants(message) do
            {:ok, delivery_results} ->
              # Marquer le message comme livré
              mark_scheduled_message_delivered(message.id)
              
              # Envoyer les notifications push si nécessaire
              send_push_notifications(message)
              
              # Mettre à jour les métriques
              update_delivery_metrics(message, delivery_results)
              
              {:ok, delivery_results}
            {:error, reason} ->
              # Marquer comme échec et programmer un retry
              mark_scheduled_message_failed(message.id, reason)
              schedule_retry_if_needed(message, reason)
              {:error, reason}
          end
        {:error, reason} ->
          Logger.warning("Scheduled message validation failed", %{
            message_id: message.id,
            reason: reason
          })
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Scheduled message delivery exception", %{
          message_id: message.id,
          error: inspect(error)
        })
        {:error, "delivery_exception: #{inspect(error)}"}
    end
  end

  defp validate_scheduled_message(message) do
    cond do
      is_nil(message.conversation_id) ->
        {:error, :missing_conversation}
      is_nil(message.sender_id) ->
        {:error, :missing_sender}
      is_nil(message.content) ->
        {:error, :missing_content}
      true ->
        :ok
    end
  end

  defp deliver_message_to_participants(message) do
    # Récupérer les participants de la conversation
    participants = get_conversation_participants(message.conversation_id)
    
    # Livrer à chaque participant
    delivery_results = Enum.map(participants, fn participant_id ->
      case deliver_to_participant(message, participant_id) do
        :ok -> {participant_id, :delivered}
        {:error, reason} -> {participant_id, {:failed, reason}}
      end
    end)
    
    # Vérifier si au moins une livraison a réussi
    successful_deliveries = Enum.count(delivery_results, fn {_, status} -> status == :delivered end)
    
    if successful_deliveries > 0 do
      {:ok, delivery_results}
    else
      {:error, :all_deliveries_failed}
    end
  end

  defp deliver_to_participant(message, participant_id) do
    try do
      # Diffuser via Phoenix Channels si connecté
      ConversationChannel.broadcast_to_user(participant_id, "new_message", %{
        message_id: message.id,
        conversation_id: message.conversation_id,
        sender_id: message.sender_id,
        content: message.content,
        sent_at: message.sent_at,
        message_type: message.message_type
      })
      
      # Créer l'entrée de statut de livraison
       create_delivery_status_entry(message.id, participant_id)
      
      :ok
    rescue
      error ->
        Logger.error("Failed to deliver to participant", %{
          message_id: message.id,
          participant_id: participant_id,
          error: inspect(error)
        })
        {:error, :delivery_failed}
    end
  end

  defp mark_scheduled_message_delivered(message_id) do
    # Mettre à jour le statut du message programmé
    Messages.update_message_status(message_id, :delivered)
  end

  defp mark_scheduled_message_failed(message_id, reason) do
    # Mettre à jour le statut du message programmé
    Messages.update_message_status(message_id, :failed, %{reason: reason})
  end

  defp schedule_retry_if_needed(message, reason) do
    # Programmer un retry selon la politique de retry
    retry_count = Map.get(message.metadata || %{}, "retry_count", 0)
    max_retries = 3
    
    if retry_count < max_retries do
      # Programmer un retry avec backoff exponentiel
      retry_delay = :math.pow(2, retry_count) * 60 # minutes
      
      # Utiliser le scheduling-service pour programmer le retry
      schedule_message_retry(message.id, retry_delay, retry_count + 1)
    else
      Logger.warning("Max retries reached for scheduled message", %{
        message_id: message.id,
        reason: reason,
        retry_count: retry_count
      })
    end
  end

  defp schedule_message_retry(message_id, delay_minutes, retry_count) do
    # TODO: Intégrer avec le scheduling-service pour programmer le retry
    Logger.info("Scheduling message retry", %{
      message_id: message_id,
      delay_minutes: delay_minutes,
      retry_count: retry_count
    })
  end

  defp update_delivery_metrics(message, delivery_results) do
    # Mettre à jour les métriques de livraison
    successful_count = Enum.count(delivery_results, fn {_, status} -> status == :delivered end)
    failed_count = length(delivery_results) - successful_count
    
    :telemetry.execute([:whispr_messaging, :delivery, :scheduled_message], %{
      delivered: successful_count,
      failed: failed_count,
      total: length(delivery_results)
    }, %{
      conversation_id: message.conversation_id,
      message_type: message.message_type
    })
  end

  @doc """
  Obtenir les statistiques de livraison pour une conversation
  """
  def get_delivery_stats_for_conversation(conversation_id, user_id) do
    # Vérifier que l'utilisateur est membre de la conversation
    case WhisprMessaging.Conversations.get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :unauthorized}
      _member ->
        # Calculer les statistiques de livraison
        stats = %{
          total_messages: count_total_messages(conversation_id),
          delivered_messages: count_delivered_messages(conversation_id),
          read_messages: count_read_messages(conversation_id),
          average_delivery_time: calculate_average_delivery_time(conversation_id),
          last_activity: get_last_activity(conversation_id)
        }
        
        {:ok, stats}
    end
  end

  # Fonctions privées pour les statistiques
  defp count_total_messages(conversation_id) do
    # Compter tous les messages de la conversation
    from(m in WhisprMessaging.Messages.Message,
      where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
      select: count(m.id)
    )
    |> WhisprMessaging.Repo.one() || 0
  end

  defp count_delivered_messages(conversation_id) do
    # Compter les messages avec au moins une livraison confirmée
    from(m in WhisprMessaging.Messages.Message,
      join: ds in WhisprMessaging.Messages.DeliveryStatus,
      on: ds.message_id == m.id,
      where: m.conversation_id == ^conversation_id and 
             is_nil(m.deleted_at) and 
             not is_nil(ds.delivered_at),
      select: count(m.id, :distinct)
    )
    |> WhisprMessaging.Repo.one() || 0
  end

  defp count_read_messages(conversation_id) do
    # Compter les messages avec au moins une lecture confirmée
    from(m in WhisprMessaging.Messages.Message,
      join: ds in WhisprMessaging.Messages.DeliveryStatus,
      on: ds.message_id == m.id,
      where: m.conversation_id == ^conversation_id and 
             is_nil(m.deleted_at) and 
             not is_nil(ds.read_at),
      select: count(m.id, :distinct)
    )
    |> WhisprMessaging.Repo.one() || 0
  end

  defp calculate_average_delivery_time(conversation_id) do
    # Calculer le temps moyen entre l'envoi et la première livraison
    query = from(m in WhisprMessaging.Messages.Message,
      join: ds in WhisprMessaging.Messages.DeliveryStatus,
      on: ds.message_id == m.id,
      where: m.conversation_id == ^conversation_id and 
             is_nil(m.deleted_at) and 
             not is_nil(ds.delivered_at),
      select: fragment("EXTRACT(EPOCH FROM (? - ?))", ds.delivered_at, m.sent_at)
    )
    
    delivery_times = WhisprMessaging.Repo.all(query)
    
    if length(delivery_times) > 0 do
      Enum.sum(delivery_times) / length(delivery_times)
    else
      0.0
    end
  end

  defp get_last_activity(conversation_id) do
    # Récupérer la dernière activité (message ou lecture)
    last_message_query = from(m in WhisprMessaging.Messages.Message,
      where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
      select: m.sent_at,
      order_by: [desc: m.sent_at],
      limit: 1
    )
    
    last_read_query = from(ds in WhisprMessaging.Messages.DeliveryStatus,
      join: m in WhisprMessaging.Messages.Message,
      on: ds.message_id == m.id,
      where: m.conversation_id == ^conversation_id and not is_nil(ds.read_at),
      select: ds.read_at,
      order_by: [desc: ds.read_at],
      limit: 1
    )
    
    last_message = WhisprMessaging.Repo.one(last_message_query)
    last_read = WhisprMessaging.Repo.one(last_read_query)
    
    case {last_message, last_read} do
      {nil, nil} -> nil
      {msg_time, nil} -> msg_time
      {nil, read_time} -> read_time
      {msg_time, read_time} -> 
        if DateTime.compare(msg_time, read_time) == :gt, do: msg_time, else: read_time
    end || DateTime.utc_now()
  end

  defp create_delivery_status_entry(message_id, participant_id) do
    # Créer une entrée de statut de livraison
    attrs = %{
      message_id: message_id,
      user_id: participant_id,
      status: :sent,
      sent_at: DateTime.utc_now()
    }
    
    case WhisprMessaging.Repo.insert(%DeliveryStatus{}, attrs) do
      {:ok, _delivery_status} -> :ok
      {:error, reason} -> 
        Logger.error("Failed to create delivery status", %{
          message_id: message_id,
          participant_id: participant_id,
          reason: inspect(reason)
        })
        {:error, reason}
    end
  end

  defp get_conversation_participants(conversation_id) do
    # Récupérer les participants de la conversation
    case WhisprMessaging.Conversations.get_conversation_participants(conversation_id) do
      {:ok, participants} -> Enum.map(participants, & &1.user_id)
      {:error, _} -> []
    end
  end

  defp send_push_notifications(message) do
    # Envoyer les notifications push via le notification-service
    case NotificationServiceClient.send_message_notification(
      message.conversation_id,
      message.sender_id,
      message.content,
      message.message_type
    ) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to send push notifications", %{
          message_id: message.id,
          reason: reason
        })
    end
  end
end
