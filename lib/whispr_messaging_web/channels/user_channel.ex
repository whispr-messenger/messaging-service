defmodule WhisprMessagingWeb.UserChannel do
  @moduledoc """
  Channel utilisateur pour la gestion de la présence et des notifications globales
  selon la documentation 9_websocket_rtc.md
  """
  use WhisprMessagingWeb, :channel

  alias Phoenix.PubSub
  alias WhisprMessaging.Conversations
  # alias WhisprMessaging.Messages (non utilisé actuellement)

  require Logger

  ## Callbacks Phoenix Channel

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    # Vérifier que l'utilisateur peut joindre ce channel
    if authorized?(socket, user_id) do
      # Enregistrer la présence
      send(self(), :after_join)
      
      {:ok, %{status: "connected", user_id: user_id}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end



  ## Messages entrants du client

  @impl true
  def handle_in("ping", payload, socket) do
    # Répondre au ping pour maintenir la connexion
    {:reply, {:ok, %{pong: payload["timestamp"]}}, socket}
  end

  @impl true
  def handle_in("update_presence", payload, socket) do
    user_id = socket.assigns.user_id
    status = payload["status"] || "online"
    
    # Mettre à jour le statut de présence
    update_user_presence(socket, user_id, status)
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("mark_all_read", %{"conversation_ids" => conversation_ids}, socket) do
    user_id = socket.assigns.user_id
    
    # Marquer plusieurs conversations comme lues
    results = Enum.map(conversation_ids, fn conversation_id ->
      case Conversations.mark_conversation_as_read(conversation_id, user_id) do
        {:ok, _} -> 
          # Broadcaster la mise à jour de lecture
          broadcast_read_status_update(user_id, conversation_id)
          {:ok, conversation_id}
        {:error, reason} -> 
          {:error, conversation_id, reason}
      end
    end)
    
    {:reply, {:ok, %{results: results}}, socket}
  end

  ## Messages entrants du PubSub

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id
    device_id = socket.assigns.device_id
    
    # Enregistrer la présence utilisateur dans Redis
    presence_metadata = %{
      devices: [device_id],
      status: "online",
      channel_joined_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
    WhisprMessaging.Cache.PresenceCache.set_user_presence(user_id, "online", presence_metadata)
    
    # Enregistrer la présence Phoenix (pour distribution locale)
    track_user_presence(socket, user_id, device_id)
    
    # S'abonner aux événements de l'utilisateur
    subscribe_to_user_events(user_id)
    
    # Récupérer et envoyer les messages en attente depuis Redis
    send_pending_messages(socket, user_id)
    
    # Mettre à jour les souscriptions de session
    session_id = socket.assigns[:session_id]
    if session_id do
      WhisprMessaging.Cache.SessionCache.update_session_subscriptions(
        session_id,
        ["user:#{user_id}"]
      )
    end
    
    # Log de la connexion réussie
    Logger.info("User joined channel", %{
      user_id: user_id,
      device_id: device_id,
      channel: "user:#{user_id}"
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    # Nouveau message reçu dans une conversation de l'utilisateur
    push(socket, "new_message", %{
      message_id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      message_type: message.message_type,
      sent_at: message.sent_at,
      preview: generate_message_preview(message)
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:conversation_updated, conversation}, socket) do
    # Conversation mise à jour (nouveau membre, paramètres, etc.)
    push(socket, "conversation_updated", %{
      conversation_id: conversation.id,
      updated_at: conversation.updated_at,
      metadata: conversation.metadata
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_presence_changed, user_id, presence_info}, socket) do
    # Changement de présence d'un contact
    push(socket, "user_presence_changed", %{
      user_id: user_id,
      status: presence_info.status,
      last_seen: presence_info.last_seen
    })
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:notification, notification}, socket) do
    # Notification système (mention, invitation, etc.)
    push(socket, "notification", notification)
    
    {:noreply, socket}
  end

  ## Lifecycle

  @impl true
  def terminate(reason, socket) do
    user_id = socket.assigns.user_id
    device_id = socket.assigns.device_id
    
    # Nettoyer la présence utilisateur
    untrack_user_presence(socket, user_id, device_id)
    
    Logger.info("User left channel", %{
      user_id: user_id,
      device_id: device_id,
      reason: reason,
      channel: "user:#{user_id}"
    })
    
    :ok
  end

  ## Fonctions publiques

  @doc """
  Notifie un nouvel message à l'utilisateur (fonction publique pour compatibilité)
  """
  def notify_new_message(user_id, message) do
    Phoenix.PubSub.broadcast(
      WhisprMessaging.PubSub,
      "user:#{user_id}:messages",
      {:new_message, message}
    )
  end

  @doc """
  Notifie le statut de livraison d'un message à l'utilisateur
  """
  def notify_delivery_status(user_id, delivery_info) do
    Phoenix.PubSub.broadcast(
      WhisprMessaging.PubSub,
      "user:#{user_id}:delivery_status",
      {:delivery_status, delivery_info}
    )
  end

  ## Fonctions privées

  defp authorized?(socket, user_id) do
    # Vérifier que l'utilisateur peut joindre son propre channel
    socket.assigns.user_id == user_id
  end

  defp track_user_presence(socket, user_id, device_id) do
    # Utiliser Phoenix.Presence pour tracker la présence
    WhisprMessagingWeb.Presence.track(socket, user_id, %{
      device_id: device_id,
      online_at: DateTime.utc_now(),
      status: "online",
      ip_address: socket.assigns[:ip_address],
      user_agent: socket.assigns[:user_agent]
    })
  end

  defp update_user_presence(socket, user_id, status) do
    # Mettre à jour le statut de présence
    WhisprMessagingWeb.Presence.update(socket, user_id, %{
      status: status,
      updated_at: DateTime.utc_now()
    })
  end

  defp untrack_user_presence(socket, user_id, _device_id) do
    # Arrêter le tracking de présence
    WhisprMessagingWeb.Presence.untrack(socket, user_id)
  end

  defp subscribe_to_user_events(user_id) do
    # S'abonner aux événements concernant cet utilisateur
    topics = [
      "user:#{user_id}:messages",      # Nouveaux messages
      "user:#{user_id}:conversations", # Mises à jour de conversations
      "user:#{user_id}:notifications", # Notifications système
      "user:#{user_id}:presence"       # Changements de présence des contacts
    ]
    
    Enum.each(topics, fn topic ->
      PubSub.subscribe(WhisprMessaging.PubSub, topic)
    end)
  end

  defp send_pending_messages(socket, user_id) do
    # Récupérer les messages en attente depuis Redis
    case WhisprMessaging.Cache.MessageQueueCache.get_pending_messages(user_id, 50) do
      {:ok, []} ->
        # Aucun message en attente
        push(socket, "sync_complete", %{
          user_id: user_id,
          pending_count: 0,
          timestamp: DateTime.utc_now()
        })
        
      {:ok, pending_messages} ->
        # Envoyer les messages en attente
        Enum.each(pending_messages, fn %{message: message_data} ->
          push(socket, "pending_message", message_data)
        end)
        
        # Confirmer la synchronisation
        push(socket, "sync_complete", %{
          user_id: user_id,
          pending_count: length(pending_messages),
          timestamp: DateTime.utc_now()
        })
        
        # Marquer les messages comme livrés (après un délai pour confirmation client)
        message_ids = Enum.map(pending_messages, fn %{message: %{id: id}} -> id end)
        Task.start(fn ->
          :timer.sleep(1000) # Attendre 1 seconde
          WhisprMessaging.Cache.MessageQueueCache.remove_delivered_messages(user_id, message_ids)
        end)
        
      {:error, reason} ->
        Logger.error("Failed to get pending messages", %{
          user_id: user_id,
          error: reason
        })
        
        push(socket, "sync_error", %{
          user_id: user_id,
          error: "failed_to_retrieve_messages",
          timestamp: DateTime.utc_now()
        })
    end
  end

  defp broadcast_read_status_update(user_id, conversation_id) do
    # Broadcaster la mise à jour de statut de lecture
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:read_status",
      {:read_status_updated, user_id, DateTime.utc_now()}
    )
  end

  defp generate_message_preview(message) do
    # Générer un aperçu sécurisé du message (sans déchiffrer le contenu)
    case message.message_type do
      "text" -> "Nouveau message"
      "media" -> "Média partagé"
      "system" -> "Notification système"
      _ -> "Nouveau message"
    end
  end
end
