defmodule WhisprMessaging.Grpc.NotificationServiceClient do
  @moduledoc """
  Client gRPC pour communiquer avec notification-service
  selon la documentation system_design.md
  """
  
  require Logger

  @service_name "notification-service"
  @default_timeout 5_000

  ## Fonctions publiques d'interface

  @doc """
  Envoyer une notification pour un nouveau message (version simplifiée)
  """
  def send_message_notification(user_id, message) do
    send_message_notification(
      message.id,
      message.conversation_id,
      message.sender_id,
      [user_id],
      message_type: message.message_type,
      preview_text: "Nouveau message"
    )
  end

  @doc """
  Notifier la création d'une nouvelle conversation
  """
  def notify_new_conversation(user_id, conversation) do
    request = %{
      user_id: user_id,
      conversation_id: conversation.id,
      conversation_type: conversation.type,
      metadata: conversation.metadata || %{}
    }
    
    make_grpc_call(:notify_new_conversation, request)
  end

  @doc """
  Envoyer une notification pour un nouveau message (version complète)
  """
  def send_message_notification(message_id, conversation_id, sender_id, recipient_ids, opts \\ []) do
    message_type = Keyword.get(opts, :message_type, "text")
    preview_text = Keyword.get(opts, :preview_text, "Nouveau message")
    metadata = Keyword.get(opts, :metadata, %{})
    priority = Keyword.get(opts, :priority, :normal)
    silent = Keyword.get(opts, :silent, false)
    
    request = %{
      message_id: message_id,
      conversation_id: conversation_id,
      sender_id: sender_id,
      recipient_ids: recipient_ids,
      message_type: message_type,
      preview_text: preview_text,
      metadata: metadata,
      priority: convert_priority(priority),
      silent: silent
    }
    
    Logger.debug("Sending message notification", %{
      message_id: message_id,
      conversation_id: conversation_id,
      recipient_count: length(recipient_ids),
      priority: priority
    })
    
    case make_grpc_call(:send_message_notification, request) do
      {:ok, response} ->
        if response.success do
          {:ok, %{
            notification_id: response.notification_id,
            delivery_statuses: parse_delivery_statuses(response.delivery_statuses)
          }}
        else
          {:error, response.message}
        end
        
      {:error, reason} ->
        Logger.error("Failed to send message notification", %{
          error: reason,
          message_id: message_id,
          conversation_id: conversation_id
        })
        {:error, reason}
    end
  end

  @doc """
  Envoyer des notifications en lot
  """
  def send_bulk_notifications(notifications, opts \\ []) do
    fail_on_error = Keyword.get(opts, :fail_on_error, false)
    batch_size = Keyword.get(opts, :batch_size, 100)
    
    request = %{
      notifications: Enum.map(notifications, &format_notification_request/1),
      fail_on_error: fail_on_error,
      batch_size: batch_size
    }
    
    Logger.debug("Sending bulk notifications", %{
      notification_count: length(notifications),
      batch_size: batch_size
    })
    
    case make_grpc_call(:send_bulk_notifications, request) do
      {:ok, response} ->
        {:ok, %{
          total_sent: response.total_sent,
          total_failed: response.total_failed,
          results: Enum.map(response.results, &parse_notification_response/1),
          errors: response.errors
        }}
        
      {:error, reason} ->
        Logger.error("Failed to send bulk notifications", %{
          error: reason,
          notification_count: length(notifications)
        })
        {:error, reason}
    end
  end

  @doc """
  Envoyer une notification d'événement de conversation
  """
  def send_conversation_notification(conversation_id, event_type, actor_id, recipient_ids, opts \\ []) do
    title = Keyword.get(opts, :title, "Mise à jour de conversation")
    body = Keyword.get(opts, :body, "")
    data = Keyword.get(opts, :data, %{})
    priority = Keyword.get(opts, :priority, :normal)
    
    request = %{
      conversation_id: conversation_id,
      event_type: event_type,
      actor_id: actor_id,
      recipient_ids: recipient_ids,
      title: title,
      body: body,
      data: data,
      priority: convert_priority(priority)
    }
    
    Logger.debug("Sending conversation notification", %{
      conversation_id: conversation_id,
      event_type: event_type,
      recipient_count: length(recipient_ids)
    })
    
    case make_grpc_call(:send_conversation_notification, request) do
      {:ok, response} ->
        if response.success do
          {:ok, %{
            notification_id: response.notification_id,
            delivery_statuses: parse_delivery_statuses(response.delivery_statuses)
          }}
        else
          {:error, response.message}
        end
        
      {:error, reason} ->
        Logger.error("Failed to send conversation notification", %{
          error: reason,
          conversation_id: conversation_id,
          event_type: event_type
        })
        {:error, reason}
    end
  end

  @doc """
  Marquer des notifications comme lues
  """
  def mark_notifications_as_read(user_id, notification_ids \\ [], conversation_id \\ nil) do
    request = %{
      user_id: user_id,
      notification_ids: notification_ids,
      conversation_id: conversation_id,
      read_at: DateTime.utc_now() |> DateTime.to_unix()
    }
    
    Logger.debug("Marking notifications as read", %{
      user_id: user_id,
      notification_count: length(notification_ids),
      conversation_id: conversation_id
    })
    
    case make_grpc_call(:mark_notifications_as_read, request) do
      {:ok, response} ->
        if response.success do
          {:ok, %{
            marked_count: response.marked_count,
            failed_notification_ids: response.failed_notification_ids
          }}
        else
          {:error, "Failed to mark notifications as read"}
        end
        
      {:error, reason} ->
        Logger.error("Failed to mark notifications as read", %{
          error: reason,
          user_id: user_id
        })
        {:error, reason}
    end
  end

  ## Fonctions privées

  defp make_grpc_call(method, request, _timeout \\ @default_timeout) do
    case get_connection() do
      {:ok, _connection} ->
        try do
          # Ici nous simulons l'appel gRPC pour l'instant
          # TODO: Implémenter l'appel gRPC réel avec grpcbox
          simulate_grpc_call(method, request)
        catch
          :exit, reason ->
            Logger.error("gRPC call failed with exit", %{
              method: method,
              reason: reason,
              service: @service_name
            })
            {:error, {:grpc_exit, reason}}
            
          kind, reason ->
            Logger.error("gRPC call failed with exception", %{
              method: method,
              kind: kind,
              reason: reason,
              service: @service_name
            })
            {:error, {:grpc_exception, {kind, reason}}}
        end
        
      
    end
  end

  defp get_connection do
    # TODO: Implémenter la gestion des connexions gRPC avec pool
    # Pour l'instant, simuler une connexion réussie
    {:ok, :mock_connection}
  end

  defp convert_priority(:low), do: 0
  defp convert_priority(:normal), do: 1
  defp convert_priority(:high), do: 2
  defp convert_priority(:urgent), do: 3
  defp convert_priority(_), do: 1

  defp format_notification_request(notification) do
    %{
      message_id: notification.message_id,
      conversation_id: notification.conversation_id,
      sender_id: notification.sender_id,
      recipient_ids: notification.recipient_ids,
      message_type: notification.message_type || "text",
      preview_text: notification.preview_text || "Nouveau message",
      metadata: notification.metadata || %{},
      priority: convert_priority(notification.priority || :normal),
      silent: notification.silent || false
    }
  end

  defp parse_notification_response(response) do
    %{
      success: response.success,
      message: response.message,
      notification_id: response.notification_id,
      delivery_statuses: parse_delivery_statuses(response.delivery_statuses)
    }
  end

  defp parse_delivery_statuses(statuses) do
    Enum.map(statuses, fn status ->
      %{
        user_id: status.user_id,
        device_id: status.device_id,
        delivered: status.delivered,
        error_message: status.error_message,
        delivered_at: status.delivered_at
      }
    end)
  end

  # Simulation temporaire des appels gRPC pour les tests
  defp simulate_grpc_call(:send_message_notification, request) do
    # Simulation basique : notification envoyée avec succès
    delivery_statuses = Enum.map(request.recipient_ids, fn user_id ->
      %{
        user_id: user_id,
        device_id: "device_#{user_id}",
        delivered: true,
        error_message: "",
        delivered_at: DateTime.utc_now() |> DateTime.to_unix()
      }
    end)
    
    {:ok, %{
      success: true,
      message: "Notification sent successfully",
      notification_id: UUID.uuid4(),
      delivery_statuses: delivery_statuses
    }}
  end

  defp simulate_grpc_call(:send_bulk_notifications, request) do
    # Simulation basique : toutes les notifications envoyées
    results = Enum.map(request.notifications, fn _notif ->
      %{
        success: true,
        message: "Notification sent",
        notification_id: UUID.uuid4(),
        delivery_statuses: []
      }
    end)
    
    {:ok, %{
      total_sent: length(request.notifications),
      total_failed: 0,
      results: results,
      errors: []
    }}
  end

  defp simulate_grpc_call(:send_conversation_notification, request) do
    # Simulation basique : notification de conversation envoyée
    delivery_statuses = Enum.map(request.recipient_ids, fn user_id ->
      %{
        user_id: user_id,
        device_id: "device_#{user_id}",
        delivered: true,
        error_message: "",
        delivered_at: DateTime.utc_now() |> DateTime.to_unix()
      }
    end)
    
    {:ok, %{
      success: true,
      message: "Conversation notification sent",
      notification_id: UUID.uuid4(),
      delivery_statuses: delivery_statuses
    }}
  end

  defp simulate_grpc_call(:mark_notifications_as_read, request) do
    # Simulation basique : notifications marquées comme lues
    marked_count = if request.conversation_id, do: 5, else: length(request.notification_ids)
    
    {:ok, %{
      success: true,
      marked_count: marked_count,
      failed_notification_ids: []
    }}
  end

  defp simulate_grpc_call(method, _request) do
    Logger.warning("Unimplemented gRPC method simulation", %{method: method})
    {:error, :method_not_implemented}
  end
end
