defmodule WhisprMessagingWeb.ConversationChannel do
  @moduledoc """
  Channel pour les conversations individuelles - messages temps réel, indicateurs de frappe
  selon la documentation 9_websocket_rtc.md
  """
  use WhisprMessagingWeb, :channel

  alias Phoenix.PubSub
  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessaging.Messages.Message

  require Logger

  ## Callbacks Phoenix Channel

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    user_id = socket.assigns.user_id
    
    # Vérifier que l'utilisateur est membre de cette conversation
    if Conversations.is_member?(conversation_id, user_id) do
      # Enregistrer la présence dans la conversation
      send(self(), {:after_join, conversation_id})
      
      {:ok, %{status: "joined", conversation_id: conversation_id}, 
       assign(socket, :conversation_id, conversation_id)}
    else
      {:error, %{reason: "not_a_member"}}
    end
  end

  @impl true
  def handle_info({:after_join, conversation_id}, socket) do
    user_id = socket.assigns.user_id
    
    # Enregistrer la présence dans la conversation via Redis
    WhisprMessaging.Cache.PresenceCache.set_conversation_presence(
      conversation_id, 
      user_id, 
      %{status: "active", joined_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    )
    
    # Tracker la présence Phoenix (pour distribution locale)
    track_conversation_presence(socket, conversation_id, user_id)
    
    # S'abonner aux événements de la conversation
    subscribe_to_conversation_events(conversation_id)
    
    # Mettre à jour les souscriptions de session
    session_id = socket.assigns[:session_id]
    if session_id do
      case WhisprMessaging.Cache.SessionCache.get_session(session_id) do
        {:ok, session_data} when not is_nil(session_data) ->
          current_subscriptions = session_data["channel_subscriptions"] || []
          new_subscriptions = ["conversation:#{conversation_id}" | current_subscriptions] |> Enum.uniq()
          WhisprMessaging.Cache.SessionCache.update_session_subscriptions(session_id, new_subscriptions)
        _ -> 
          :ok
      end
    end
    
    # Broadcaster que l'utilisateur a rejoint
    broadcast_user_joined(conversation_id, user_id)
    
    Logger.info("User joined conversation channel", %{
      user_id: user_id,
      conversation_id: conversation_id
    })
    
    {:noreply, socket}
  end

  ## Messages entrants du PubSub

  @impl true
  def handle_info({:new_message, message}, socket) do
    # Nouveau message dans la conversation
    push(socket, "new_message", format_message_for_client(message))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:typing_indicator, user_id, action}, socket) do
    # Indicateur de frappe d'un autre utilisateur
    if user_id != socket.assigns.user_id do
      push(socket, "typing_indicator", %{
        user_id: user_id,
        action: action,
        timestamp: DateTime.utc_now()
      })
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:typing_timeout, user_id}, socket) do
    conversation_id = socket.assigns.conversation_id
    
    # Arrêt automatique de l'indicateur de frappe
    if user_id == socket.assigns.user_id do
      broadcast_typing_indicator(conversation_id, user_id, "stop")
    end
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:read_receipt, message_id, user_id}, socket) do
    # Accusé de lecture d'un message
    push(socket, "read_receipt", %{
      message_id: message_id,
      user_id: user_id,
      read_at: DateTime.utc_now()
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:reaction_added, message_id, user_id, reaction}, socket) do
    # Nouvelle réaction ajoutée
    push(socket, "reaction_added", %{
      message_id: message_id,
      user_id: user_id,
      reaction: reaction,
      timestamp: DateTime.utc_now()
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:reaction_removed, message_id, user_id, reaction}, socket) do
    # Réaction supprimée
    push(socket, "reaction_removed", %{
      message_id: message_id,
      user_id: user_id,
      reaction: reaction,
      timestamp: DateTime.utc_now()
    })
    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_joined, user_id}, socket) do
    # Utilisateur a rejoint la conversation
    if user_id != socket.assigns.user_id do
      push(socket, "user_joined", %{
        user_id: user_id,
        timestamp: DateTime.utc_now()
      })
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:user_left, user_id}, socket) do
    # Utilisateur a quitté la conversation
    push(socket, "user_left", %{
      user_id: user_id,
      timestamp: DateTime.utc_now()
    })
    {:noreply, socket}
  end

  ## Messages entrants du client

  @impl true
  def handle_in("send_message", payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    trust_level = socket.assigns[:trust_level] || "normal"
    
    # Validation de sécurité complète
    with :ok <- WhisprMessaging.Security.Middleware.validate_message_size(payload["content"] || ""),
         {:ok, _rate_info} <- WhisprMessaging.Security.RateLimiter.check_rate_limit(
           user_id, 
           payload["message_type"] || "message", 
           trust_level: trust_level
         ),
         :ok <- validate_message_content(payload),
         :ok <- check_conversation_permissions(user_id, conversation_id, "write") do
      
      # Créer le message avec validation réussie
      message_attrs = %{
        "conversation_id" => conversation_id,
        "sender_id" => user_id,
        "message_type" => payload["message_type"] || "text",
        "content" => payload["content"],
        "metadata" => payload["metadata"] || %{},
        "client_random" => payload["client_random"] || :rand.uniform(1_000_000_000),
        "reply_to_id" => payload["reply_to_id"]
      }
      
      case Messages.create_message(message_attrs) do
        {:ok, message} ->
          # Enregistrer l'activité pour détection de patterns
          WhisprMessaging.Security.Middleware.detect_suspicious_activity(
            user_id,
            "message_sent",
            %{conversation_id: conversation_id, message_type: payload["message_type"] || "text"}
          )
          
          # Broadcaster le message à tous les membres de la conversation
          broadcast_new_message(conversation_id, message)
          
          # Répondre au client avec le message créé
          {:reply, {:ok, %{message_id: message.id, sent_at: message.sent_at}}, socket}
          
        {:error, changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
          {:reply, {:error, %{errors: errors}}, socket}
      end
    else
      {:error, {:rate_limit_exceeded, rate_info}} ->
        Logger.warning("Message rate limit exceeded", %{
          user_id: user_id,
          conversation_id: conversation_id,
          rate_info: rate_info
        })
        {:reply, {:error, %{reason: "rate_limit_exceeded", retry_after: rate_info.retry_after}}, socket}
        
      {:error, :message_too_large} ->
        {:reply, {:error, %{reason: "message_too_large"}}, socket}
        
      {:error, reason} ->
        Logger.warning("Message validation failed", %{
          user_id: user_id,
          conversation_id: conversation_id,
          reason: reason
        })
        {:reply, {:error, %{reason: "validation_failed"}}, socket}
    end
  end

  @impl true
  def handle_in("typing_start", _payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    # Enregistrer l'indicateur de frappe dans Redis
    WhisprMessaging.Cache.PresenceCache.set_typing_indicator(conversation_id, user_id, true)
    
    # Broadcaster que l'utilisateur est en train de taper
    broadcast_typing_indicator(conversation_id, user_id, "start")
    
    # Programmer l'arrêt automatique après 10 secondes (expiration Redis)
    Process.send_after(self(), {:typing_timeout, user_id}, 10_000)
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("typing_stop", _payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    # Supprimer l'indicateur de frappe de Redis
    WhisprMessaging.Cache.PresenceCache.set_typing_indicator(conversation_id, user_id, false)
    
    # Broadcaster que l'utilisateur a arrêté de taper
    broadcast_typing_indicator(conversation_id, user_id, "stop")
    
    {:noreply, socket}
  end

  @impl true
  def handle_in("mark_as_read", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    case Messages.mark_message_as_read(message_id, user_id) do
      :ok ->
        # Broadcaster la mise à jour de lecture
        broadcast_read_receipt(conversation_id, message_id, user_id)
        {:reply, {:ok, %{marked_read: true}}, socket}
        
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("add_reaction", %{"message_id" => message_id, "reaction" => reaction}, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    case Messages.add_reaction_to_message(message_id, user_id, reaction) do
      {:ok, _reaction} ->
        # Broadcaster la nouvelle réaction
        broadcast_reaction_added(conversation_id, message_id, user_id, reaction)
        {:reply, {:ok, %{reaction_added: true}}, socket}
        
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("remove_reaction", %{"message_id" => message_id, "reaction" => reaction}, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    case Messages.remove_reaction_from_message(message_id, user_id, reaction) do
      :ok ->
        # Broadcaster la suppression de réaction
        broadcast_reaction_removed(conversation_id, message_id, user_id, reaction)
        {:reply, {:ok, %{reaction_removed: true}}, socket}
        
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  ## Lifecycle

  @impl true
  def terminate(reason, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id
    
    # Nettoyer la présence dans Redis
    WhisprMessaging.Cache.PresenceCache.remove_conversation_presence(conversation_id, user_id)
    
    # Supprimer les indicateurs de frappe
    WhisprMessaging.Cache.PresenceCache.set_typing_indicator(conversation_id, user_id, false)
    
    # Nettoyer la présence Phoenix
    untrack_conversation_presence(socket, conversation_id, user_id)
    
    # Broadcaster que l'utilisateur a quitté
    broadcast_user_left(conversation_id, user_id)
    
    Logger.info("User left conversation channel", %{
      user_id: user_id,
      conversation_id: conversation_id,
      reason: reason
    })
    
    :ok
  end

  ## Fonctions privées

  defp track_conversation_presence(socket, _conversation_id, user_id) do
    # Utiliser Phoenix.Presence pour tracker la présence dans la conversation
    WhisprMessagingWeb.ConversationPresence.track(socket, user_id, %{
      joined_at: DateTime.utc_now(),
      status: "active"
    })
  end

  defp untrack_conversation_presence(socket, _conversation_id, user_id) do
    WhisprMessagingWeb.ConversationPresence.untrack(socket, user_id)
  end

  defp subscribe_to_conversation_events(conversation_id) do
    # S'abonner aux événements de la conversation
    topics = [
      "conversation:#{conversation_id}:messages",
      "conversation:#{conversation_id}:typing",
      "conversation:#{conversation_id}:presence",
      "conversation:#{conversation_id}:reactions",
      "conversation:#{conversation_id}:read_status"
    ]
    
    Enum.each(topics, fn topic ->
      PubSub.subscribe(WhisprMessaging.PubSub, topic)
    end)
  end

  @doc """
  Broadcaster un nouveau message (fonction publique pour compatibilité)
  """
  def broadcast_new_message(message) do
    broadcast_new_message(message.conversation_id, message)
  end

  defp broadcast_new_message(conversation_id, message) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:messages",
      {:new_message, message}
    )
  end

  defp broadcast_typing_indicator(conversation_id, user_id, action) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:typing",
      {:typing_indicator, user_id, action}
    )
  end

  defp broadcast_read_receipt(conversation_id, message_id, user_id) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:read_status",
      {:read_receipt, message_id, user_id}
    )
  end

  defp broadcast_reaction_added(conversation_id, message_id, user_id, reaction) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:reactions",
      {:reaction_added, message_id, user_id, reaction}
    )
  end

  defp broadcast_reaction_removed(conversation_id, message_id, user_id, reaction) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:reactions",
      {:reaction_removed, message_id, user_id, reaction}
    )
  end

  defp broadcast_user_joined(conversation_id, user_id) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:presence",
      {:user_joined, user_id}
    )
  end

  defp broadcast_user_left(conversation_id, user_id) do
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:presence",
      {:user_left, user_id}
    )
  end

  defp format_message_for_client(%Message{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      reply_to_id: message.reply_to_id,
      message_type: message.message_type,
      content: Base.encode64(message.content), # Contenu déjà chiffré
      metadata: message.metadata,
      sent_at: message.sent_at,
      edited_at: message.edited_at,
      reactions: format_reactions(message.reactions || []),
      attachments: format_attachments(message.attachments || [])
    }
  end

  defp format_reactions(reactions) do
    Enum.map(reactions, fn reaction ->
      %{
        user_id: reaction.user_id,
        reaction: reaction.reaction,
        created_at: reaction.created_at
      }
    end)
  end

  defp format_attachments(attachments) do
    Enum.map(attachments, fn attachment ->
      %{
        media_id: attachment.media_id,
        media_type: attachment.media_type,
        metadata: attachment.metadata
      }
    end)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  ## Fonctions de validation de sécurité

  defp validate_message_content(payload) do
    content = payload["content"] || ""
    message_type = payload["message_type"] || "text"
    
    cond do
      # Validation basique du contenu
      String.trim(content) == "" and message_type == "text" ->
        {:error, :empty_content}
        
      # Vérifier les caractères suspicieux
      String.contains?(content, ["<script", "javascript:", "data:text/html"]) ->
        {:error, :potentially_malicious_content}
        
      # Vérifier les patterns de spam
      excessive_repetition?(content) ->
        {:error, :spam_pattern_detected}
        
      # Validation passée
      true ->
        :ok
    end
  end

  defp check_conversation_permissions(user_id, conversation_id, _action) do
    # TODO: Implémenter la vérification des permissions avec user-service
    # Pour l'instant, vérifier seulement que la conversation existe
    case Conversations.is_member?(conversation_id, user_id) do
      true -> :ok
      false -> {:error, :not_authorized}
    end
  end

  defp excessive_repetition?(content) do
    # Détecter la répétition excessive (pattern de spam)
    words = String.split(content, ~r/\s+/)
    word_count = length(words)
    
    if word_count > 5 do
      unique_words = words |> Enum.uniq() |> length()
      repetition_ratio = word_count / unique_words
      repetition_ratio > 3.0 # Plus de 3x de répétition en moyenne
    else
      false
    end
  end
end
