defmodule WhisprMessaging.Messages.Delivery do
  @moduledoc """
  Module de livraison et distribution des messages selon system_design.md
  Gère l'envoi en temps réel, les notifications push et les accusés de réception.
  """
  
  require Logger
  
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Messages
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
  defp deliver_scheduled_message(_message) do
    try do
      # Simuler la livraison d'un message programmé
      # TODO: Implémenter la logique réelle de livraison
      
      # Pour l'instant, simuler un échec aléatoire pour tester
      if :rand.uniform(100) > 95 do
        {:error, "delivery_failed"}
      else
        {:ok, :delivered}
      end
    rescue
      error ->
        {:error, "delivery_exception: #{inspect(error)}"}
    end
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
  defp count_total_messages(_conversation_id) do
    # TODO: Implémenter le comptage des messages
    0
  end

  defp count_delivered_messages(_conversation_id) do
    # TODO: Implémenter le comptage des messages livrés
    0
  end

  defp count_read_messages(_conversation_id) do
    # TODO: Implémenter le comptage des messages lus
    0
  end

  defp calculate_average_delivery_time(_conversation_id) do
    # TODO: Implémenter le calcul du temps de livraison moyen
    0.0
  end

  defp get_last_activity(_conversation_id) do
    # TODO: Implémenter la récupération de la dernière activité
    DateTime.utc_now()
  end
end
