defmodule WhisprMessaging.Grpc.MessagingServiceImpl do
  @moduledoc """
  Implémentation du service gRPC exposé par messaging-service
  selon la documentation 9_websocket_rtc.md et system_design.md
  """
  
  alias WhisprMessaging.{Conversations, Messages}
  alias Phoenix.PubSub
  
  require Logger

  ## Fonctions du service gRPC

  @doc """
  Notifier d'un événement de conversation (nouveau membre, etc.)
  """
  def notify_conversation_event(request, _stream) do
    Logger.info("gRPC: notify_conversation_event called", %{
      conversation_id: request.conversation_id,
      event_type: request.event_type,
      user_id: request.user_id
    })
    
    case handle_conversation_event(request) do
      {:ok, event_id} ->
        %{
          success: true,
          message: "Event processed successfully",
          event_id: event_id
        }
        
      {:error, reason} ->
        Logger.error("Failed to process conversation event", %{
          reason: reason,
          request: request
        })
        
        %{
          success: false,
          message: "Failed to process event: #{reason}",
          event_id: ""
        }
    end
  end

  @doc """
  Lier un média à un message
  """
  def link_media_to_message(request, _stream) do
    Logger.info("gRPC: link_media_to_message called", %{
      message_id: request.message_id,
      media_id: request.media_id,
      media_type: request.media_type
    })
    
    case handle_media_link(request) do
      {:ok, link_id} ->
        %{
          success: true,
          message: "Media linked successfully",
          link_id: link_id
        }
        
      {:error, reason} ->
        Logger.error("Failed to link media to message", %{
          reason: reason,
          request: request
        })
        
        %{
          success: false,
          message: "Failed to link media: #{reason}",
          link_id: ""
        }
    end
  end

  @doc """
  Obtenir des statistiques de conversation
  """
  def get_conversation_stats(request, _stream) do
    Logger.info("gRPC: get_conversation_stats called", %{
      conversation_id: request.conversation_id,
      user_id: request.user_id,
      metrics: request.metrics
    })
    
          case handle_conversation_stats(request) do
        {:ok, stats} ->
          %{
            success: true,
            stats: stats,
            last_updated: DateTime.utc_now() |> DateTime.to_unix()
          }
      end
  end

  @doc """
  Notifier de la création d'un groupe
  """
  def notify_group_creation(request, _stream) do
    Logger.info("gRPC: notify_group_creation called", %{
      group_id: request.group_id,
      creator_id: request.creator_id,
      member_count: length(request.member_ids)
    })
    
    case handle_group_creation(request) do
      {:ok, conversation_id} ->
        %{
          success: true,
          message: "Group conversation created successfully",
          conversation_id: conversation_id
        }
        
      {:error, reason} ->
        Logger.error("Failed to create group conversation", %{
          reason: reason,
          request: request
        })
        
        %{
          success: false,
          message: "Failed to create group: #{reason}",
          conversation_id: ""
        }
    end
  end

  ## Fonctions privées de traitement

  defp handle_conversation_event(request) do
    case request.event_type do
      "member_added" ->
        handle_member_added(request)
        
      "member_removed" ->
        handle_member_removed(request)
        
      "settings_changed" ->
        handle_settings_changed(request)
        
      _ ->
        {:error, "unknown_event_type"}
    end
  end

  defp handle_member_added(request) do
    conversation_id = request.conversation_id
    user_id = request.user_id
    
    # Vérifier que la conversation existe
    case Conversations.get_conversation(conversation_id) do
      {:error, :not_found} ->
        {:error, "conversation_not_found"}
        
      {:ok, _conversation} ->
        # Broadcaster l'événement via PubSub
        event_id = UUID.uuid4()
        
        PubSub.broadcast(
          WhisprMessaging.PubSub,
          "conversation:#{conversation_id}:events",
          {:member_added, user_id, request.metadata, event_id}
        )
        
        # Notifier le channel utilisateur
        PubSub.broadcast(
          WhisprMessaging.PubSub,
          "user:#{user_id}:conversations",
          {:conversation_updated, conversation_id, "member_added"}
        )
        
        {:ok, event_id}
    end
  end

  defp handle_member_removed(request) do
    conversation_id = request.conversation_id
    user_id = request.user_id
    
    # Vérifier que la conversation existe
    case Conversations.get_conversation(conversation_id) do
      {:error, :not_found} ->
        {:error, "conversation_not_found"}
        
      {:ok, _conversation} ->
        # Broadcaster l'événement via PubSub
        event_id = UUID.uuid4()
        
        PubSub.broadcast(
          WhisprMessaging.PubSub,
          "conversation:#{conversation_id}:events",
          {:member_removed, user_id, request.metadata, event_id}
        )
        
        {:ok, event_id}
    end
  end

  defp handle_settings_changed(request) do
    conversation_id = request.conversation_id
    
    # Broadcaster l'événement via PubSub
    event_id = UUID.uuid4()
    
    PubSub.broadcast(
      WhisprMessaging.PubSub,
      "conversation:#{conversation_id}:events",
      {:settings_changed, request.metadata, event_id}
    )
    
    {:ok, event_id}
  end

  defp handle_media_link(request) do
    message_id = request.message_id
    media_id = request.media_id
    media_type = request.media_type
    metadata = request.metadata || %{}
    
    # Créer l'attachement en base de données
    attachment_attrs = %{
      "message_id" => message_id,
      "media_id" => media_id,
      "media_type" => media_type,
      "metadata" => metadata
    }
    
    case Messages.create_message_attachment(attachment_attrs) do
      {:ok, attachment} ->
        # Broadcaster la mise à jour via PubSub
        PubSub.broadcast(
          WhisprMessaging.PubSub,
          "message:#{message_id}:attachments",
          {:media_linked, attachment}
        )
        
        {:ok, attachment.id}
        
      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:error, "validation_failed: #{inspect(errors)}"}
    end
  end

  defp handle_conversation_stats(request) do
    conversation_id = request.conversation_id
    user_id = request.user_id
    requested_metrics = request.metrics
    
    # Construire les statistiques demandées
    stats = Enum.reduce(requested_metrics, %{}, fn metric, acc ->
      case metric do
        "message_count" ->
          count = Messages.get_message_count_for_conversation(conversation_id)
          Map.put(acc, "message_count", count)
          
        "unread_count" ->
          count = Messages.get_unread_count_for_user(conversation_id, user_id)
          Map.put(acc, "unread_count", count)
          
        "last_activity" ->
          last_activity = Conversations.get_last_activity(conversation_id)
          timestamp = if last_activity, do: DateTime.to_unix(last_activity), else: 0
          Map.put(acc, "last_activity", timestamp)
          
        _ ->
          # Métrique non supportée, ignorer
          acc
      end
    end)
    
    {:ok, stats}
  end

  defp handle_group_creation(request) do
    # Créer la conversation de groupe
    conversation_attrs = %{
      "type" => "group",
      "metadata" => %{
        "group_id" => request.group_id,
        "name" => request.group_name,
        "settings" => request.settings || %{}
      }
    }
    
    case Conversations.create_conversation(conversation_attrs) do
      {:ok, conversation} ->
        # Ajouter tous les membres (créateur + membres)
        all_member_ids = [request.creator_id | request.member_ids] |> Enum.uniq()
        
        Enum.each(all_member_ids, fn member_id ->
          member_attrs = %{
            "conversation_id" => conversation.id,
            "user_id" => member_id,
            "role" => if(member_id == request.creator_id, do: "admin", else: "member"),
            "is_active" => true
          }
          
          Conversations.add_conversation_member(member_attrs)
        end)
        
        # Broadcaster la création du groupe
        PubSub.broadcast(
          WhisprMessaging.PubSub,
          "groups:created",
          {:group_created, conversation.id, request.group_id, all_member_ids}
        )
        
        {:ok, conversation.id}
        
      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:error, "conversation_creation_failed: #{inspect(errors)}"}
    end
  end
end
