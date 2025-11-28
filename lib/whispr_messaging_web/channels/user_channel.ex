defmodule WhisprMessagingWeb.UserChannel do
  @moduledoc """
  Phoenix Channel for user-specific notifications and events.

  Handles delivery statuses, read receipts, presence updates,
  and other user-specific real-time events.
  """

  use WhisprMessagingWeb, :channel

  alias WhisprMessaging.{Messages, Conversations}
  alias WhisprMessagingWeb.Presence

  require Logger

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    # Verify user can only join their own channel
    if socket.assigns.user_id == user_id do
      # Track global user presence
      send(self(), :after_join)

      {:ok, %{user_id: user_id}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.user_id

    # Track global presence
    {:ok, _} =
      Presence.track(socket, user_id, %{
        online_at: inspect(System.system_time(:second)),
        status: "online"
      })

    # Send any pending delivery confirmations
    send_pending_delivery_statuses(socket)

    # Send conversation summaries
    send_conversation_summaries(socket)

    {:noreply, socket}
  end

  # Handle user status updates
  @impl true
  def handle_in("update_status", %{"status" => status}, socket)
      when status in ["online", "away", "busy", "offline"] do
    user_id = socket.assigns.user_id

    {:ok, _} =
      Presence.update(socket, user_id, %{
        online_at: inspect(System.system_time(:second)),
        status: status
      })

    # Broadcast status change to user's conversations
    broadcast_status_to_conversations(user_id, status)

    {:reply, {:ok, %{status: status}}, socket}
  end

  def handle_in("update_status", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_status"}}, socket}
  end

  # Handle conversation list request
  def handle_in("get_conversations", _payload, socket) do
    user_id = socket.assigns.user_id

    case Conversations.list_user_conversations(user_id) do
      {:ok, conversations} ->
        serialized_conversations = Enum.map(conversations, &serialize_conversation_summary/1)
        {:reply, {:ok, %{conversations: serialized_conversations}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle unread messages request
  def handle_in("get_unread_messages", _payload, socket) do
    user_id = socket.assigns.user_id

    case Messages.get_unread_messages_for_user(user_id) do
      {:ok, unread_messages} ->
        serialized_messages = Enum.map(unread_messages, &serialize_message_summary/1)
        {:reply, {:ok, %{unread_messages: serialized_messages}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle mark all as read for a conversation
  def handle_in("mark_conversation_read", %{"conversation_id" => conversation_id}, socket) do
    user_id = socket.assigns.user_id

    case Messages.mark_conversation_read(conversation_id, user_id) do
      {:ok, count} ->
        # Broadcast read status to conversation
        WhisprMessagingWeb.Endpoint.broadcast(
          "conversation:#{conversation_id}",
          "conversation_read",
          %{
            user_id: user_id,
            read_at: DateTime.utc_now(),
            message_count: count
          }
        )

        {:reply, {:ok, %{messages_marked: count}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle presence diff events
  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  # Handle incoming delivery status notifications
  def handle_info({:delivery_status, message_id, user_id, status, timestamp}, socket) do
    push(socket, "delivery_status", %{
      message_id: message_id,
      user_id: user_id,
      status: status,
      timestamp: timestamp
    })

    {:noreply, socket}
  end

  # Handle incoming conversation invitations
  def handle_info({:conversation_invitation, conversation_id, inviter_id}, socket) do
    case Conversations.get_conversation(conversation_id) do
      {:ok, conversation} ->
        push(socket, "conversation_invitation", %{
          conversation: serialize_conversation_summary(conversation),
          inviter_id: inviter_id,
          timestamp: DateTime.utc_now()
        })

      _ ->
        Logger.warning("Failed to fetch conversation #{conversation_id} for invitation")
    end

    {:noreply, socket}
  end

  # Private functions

  defp send_pending_delivery_statuses(socket) do
    user_id = socket.assigns.user_id

    # This would typically be handled by a background process
    # that tracks pending delivery confirmations and sends them
    # when users come online
    spawn(fn ->
      case Messages.get_pending_delivery_confirmations(user_id) do
        {:ok, confirmations} ->
          Enum.each(confirmations, fn confirmation ->
            send(
              self(),
              {:delivery_status, confirmation.message_id, confirmation.user_id,
               confirmation.status, confirmation.timestamp}
            )
          end)

        _ ->
          :ok
      end
    end)
  end

  defp send_conversation_summaries(socket) do
    user_id = socket.assigns.user_id

    spawn(fn ->
      case Conversations.get_conversation_summaries(user_id) do
        {:ok, summaries} ->
          WhisprMessagingWeb.Endpoint.broadcast(
            "user:#{user_id}",
            "conversation_summaries",
            %{summaries: Enum.map(summaries, &serialize_conversation_summary/1)}
          )

        _ ->
          :ok
      end
    end)
  end

  defp broadcast_status_to_conversations(user_id, status) do
    case Conversations.get_user_active_conversations(user_id) do
      {:ok, conversation_ids} ->
        Enum.each(conversation_ids, fn conversation_id ->
          WhisprMessagingWeb.Endpoint.broadcast(
            "conversation:#{conversation_id}",
            "user_status_changed",
            %{
              user_id: user_id,
              status: status,
              timestamp: DateTime.utc_now()
            }
          )
        end)

      _ ->
        :ok
    end
  end

  defp serialize_conversation_summary(conversation) do
    %{
      id: conversation.id,
      type: conversation.type,
      metadata: conversation.metadata,
      is_active: conversation.is_active,
      unread_count: Map.get(conversation, :unread_count, 0),
      last_message: Map.get(conversation, :last_message),
      updated_at: conversation.updated_at
    }
  end

  defp serialize_message_summary(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      message_type: message.message_type,
      metadata: message.metadata,
      sent_at: message.sent_at,
      is_deleted: message.is_deleted
    }
  end
end
