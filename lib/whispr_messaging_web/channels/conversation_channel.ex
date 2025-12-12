defmodule WhisprMessagingWeb.ConversationChannel do
  @moduledoc """
  Phoenix Channel for real-time conversation messaging.

  Handles message sending, delivery confirmations, typing indicators,
  read receipts, and other real-time conversation events.
  """

  use WhisprMessagingWeb, :channel

  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Conversations.ConversationMember
  alias WhisprMessagingWeb.Presence

  require Logger

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    user_id = socket.assigns.user_id

    case verify_conversation_access(conversation_id, user_id) do
      {:ok, conversation} ->
        # Track user presence in conversation
        send(self(), :after_join)

        socket = assign(socket, :conversation_id, conversation_id)
        {:ok, %{conversation: conversation}, socket}

      {:error, :not_member} ->
        {:error, %{reason: "not_authorized"}}

      {:error, :not_found} ->
        {:error, %{reason: "conversation_not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    # Track presence
    {:ok, _} =
      Presence.track(socket, user_id, %{
        online_at: inspect(System.system_time(:second)),
        conversation_id: conversation_id
      })

    # Push presence state to client
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  # Handle new message sending
  @impl true
  def handle_in(
        "new_message",
        %{
          "content" => encrypted_content,
          "message_type" => message_type,
          "client_random" => client_random
        } = payload,
        socket
      ) do
    conversation_id = socket.assigns.conversation_id
    sender_id = socket.assigns.user_id
    metadata = Map.get(payload, "metadata", %{})

    with {:ok, message} <-
           Messages.create_message(%{
             conversation_id: conversation_id,
             sender_id: sender_id,
             message_type: message_type,
             content: encrypted_content,
             client_random: client_random,
             metadata: metadata
           }) do
      # Broadcast message to all conversation members
      broadcast_message(socket, message)

      # Create delivery statuses for recipients
      Messages.create_delivery_statuses_for_conversation(
        message.id,
        conversation_id,
        sender_id
      )

      {:reply, {:ok, %{message: serialize_message(message)}}, socket}
    else
      {:error, changeset} ->
        {:reply, {:error, %{errors: format_changeset_errors(changeset)}}, socket}
    end
  end

  # Handle invalid new_message payload
  def handle_in("new_message", _payload, socket) do
    {:reply,
     {:error,
      %{
        reason: "invalid_payload",
        details: "content, message_type, and client_random are required"
      }}, socket}
  end

  # Handle message editing
  def handle_in(
        "edit_message",
        %{
          "message_id" => message_id,
          "content" => new_content,
          "metadata" => metadata
        },
        socket
      ) do
    user_id = socket.assigns.user_id

    case Messages.edit_message(message_id, user_id, new_content, metadata || %{}) do
      {:ok, message} ->
        broadcast(socket, "message_edited", %{
          message: serialize_message(message)
        })

        {:reply, {:ok, %{message: serialize_message(message)}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "message_not_found"}}, socket}

      {:error, :not_editable} ->
        {:reply, {:error, %{reason: "message_not_editable"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  # Handle message deletion
  def handle_in(
        "delete_message",
        %{
          "message_id" => message_id,
          "delete_for_everyone" => delete_for_everyone
        },
        socket
      ) do
    user_id = socket.assigns.user_id

    case Messages.delete_message(message_id, user_id, delete_for_everyone) do
      {:ok, message} ->
        broadcast(socket, "message_deleted", %{
          message_id: message_id,
          delete_for_everyone: delete_for_everyone
        })

        {:reply, {:ok, %{message: serialize_message(message)}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "message_not_found"}}, socket}

      {:error, :not_deletable} ->
        {:reply, {:error, %{reason: "message_not_deletable"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  # Handle message delivery confirmation
  def handle_in("message_delivered", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.user_id

    case Messages.mark_message_delivered(message_id, user_id) do
      {:ok, delivery_status} ->
        # Notify sender about delivery
        notify_sender_delivery_status(message_id, user_id, "delivered")
        {:reply, {:ok, %{status: "delivered"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle message read confirmation
  def handle_in("message_read", %{"message_id" => message_id}, socket) do
    user_id = socket.assigns.user_id

    case Messages.mark_message_read(message_id, user_id) do
      {:ok, delivery_status} ->
        # Notify sender about read receipt
        notify_sender_delivery_status(message_id, user_id, "read")
        {:reply, {:ok, %{status: "read"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle typing indicators
  def handle_in("typing_start", _payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id

    broadcast_from(socket, "user_typing", %{
      user_id: user_id,
      conversation_id: conversation_id,
      typing: true
    })

    {:noreply, socket}
  end

  def handle_in("typing_stop", _payload, socket) do
    user_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id

    broadcast_from(socket, "user_typing", %{
      user_id: user_id,
      conversation_id: conversation_id,
      typing: false
    })

    {:noreply, socket}
  end

  # Handle message reactions
  def handle_in(
        "add_reaction",
        %{
          "message_id" => message_id,
          "reaction" => reaction
        },
        socket
      ) do
    user_id = socket.assigns.user_id

    case Messages.add_reaction(message_id, user_id, reaction) do
      {:ok, message_reaction} ->
        broadcast(socket, "reaction_added", %{
          message_id: message_id,
          user_id: user_id,
          reaction: reaction
        })

        {:reply, {:ok, %{reaction: serialize_reaction(message_reaction)}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{errors: format_changeset_errors(changeset)}}, socket}
    end
  end

  def handle_in(
        "remove_reaction",
        %{
          "message_id" => message_id,
          "reaction" => reaction
        },
        socket
      ) do
    user_id = socket.assigns.user_id

    case Messages.remove_reaction(message_id, user_id, reaction) do
      {:ok, _} ->
        broadcast(socket, "reaction_removed", %{
          message_id: message_id,
          user_id: user_id,
          reaction: reaction
        })

        {:reply, {:ok, %{status: "removed"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "reaction_not_found"}}, socket}
    end
  end

  # Handle presence diff events
  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  # Private functions

  defp verify_conversation_access(conversation_id, user_id) do
    # First check if conversation exists
    case Conversations.get_conversation(conversation_id) do
      {:ok, conversation} ->
        # Then check membership
        case Conversations.get_conversation_member(conversation_id, user_id) do
          %ConversationMember{is_active: true} ->
            {:ok, conversation}

          _ ->
            {:error, :not_member}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp broadcast_message(socket, %Message{} = message) do
    broadcast(socket, "new_message", %{
      message: serialize_message(message)
    })
  end

  defp notify_sender_delivery_status(message_id, user_id, status) do
    case Messages.get_message_sender(message_id) do
      {:ok, sender_id} when sender_id != user_id ->
        WhisprMessagingWeb.Endpoint.broadcast(
          "user:#{sender_id}",
          "delivery_status",
          %{
            message_id: message_id,
            user_id: user_id,
            status: status,
            timestamp: DateTime.utc_now()
          }
        )

      _ ->
        :ok
    end
  end

  defp serialize_message(%Message{} = message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      reply_to_id: message.reply_to_id,
      message_type: message.message_type,
      content: message.content,
      metadata: message.metadata,
      client_random: message.client_random,
      sent_at: message.sent_at,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      delete_for_everyone: message.delete_for_everyone,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }
  end

  defp serialize_reaction(reaction) do
    %{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      reaction: reaction.reaction,
      inserted_at: reaction.inserted_at
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
