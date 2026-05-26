defmodule WhisprMessagingWeb.ConversationChannel do
  @moduledoc """
  Phoenix Channel for real-time conversation messaging.

  Handles message sending, delivery confirmations, typing indicators,
  read receipts, and other real-time conversation events.
  """

  use WhisprMessagingWeb, :channel

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ConversationMember
  alias WhisprMessaging.ConversationServer
  alias WhisprMessaging.ConversationSupervisor
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Services.UserService
  alias WhisprMessagingWeb.Presence

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  require Logger

  # WHISPR-1364: on intercepte les events qui transportent un sender pour
  # pouvoir filtrer par destinataire (skip si le sender est bloque par
  # l'user assis derriere ce socket). Le filtrage cote pid est le seul
  # endroit ou on connait l'identite du destinataire ; un broadcast topic
  # `conversation:<id>` ne sait pas qui est sur le canal.
  #
  # WHISPR-1390: on intercept aussi `force_leave` pour fermer le socket
  # du membre kick (sinon il reste joined apres remove_member et peut
  # continuer a envoyer des messages jusqu'a leave manuel).
  intercept ["new_message", "message_edited", "reaction_added", "reaction_removed", "force_leave"]

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    user_id = socket.assigns.user_id

    case verify_conversation_access(conversation_id, user_id) do
      {:ok, conversation} ->
        # Ensure ConversationServer is running
        case ConversationSupervisor.start_conversation(conversation_id) do
          {:ok, _pid} ->
            # Track user presence in conversation
            send(self(), :after_join)

            socket = assign(socket, :conversation_id, conversation_id)

            {:ok,
             %{
               conversation: %{
                 id: conversation.id,
                 type: conversation.type,
                 metadata: conversation.metadata,
                 is_active: conversation.is_active
               }
             }, socket}

          {:error, reason} ->
            Logger.error("Failed to start conversation server",
              conversation_id: conversation_id,
              reason: inspect(reason),
              domain: :channel
            )

            {:error, %{reason: "internal_server_error"}}
        end

      {:error, :not_member} ->
        {:error, %{reason: "not_authorized"}}

      {:error, :blocked} ->
        # WHISPR-1364: conv directe entre A et B, l'un des deux a bloque
        # l'autre -> on refuse le join. Pour les groupes le block est
        # honore via le filtre handle_out, l'user reste membre.
        {:error, %{reason: "blocked"}}

      {:error, :not_found} ->
        {:error, %{reason: "conversation_not_found"}}
    end
  end

  # WHISPR-1364: filtre par destinataire avant push vers le socket. Si le
  # sender du payload est dans la set des users bloques par l'user assis
  # derriere ce socket, on skip silencieusement. Symetrie : peu importe
  # qui a bloque qui (A bloque B ou B bloque A), aucun broadcast entre
  # eux.
  @impl true
  def handle_out(event, payload, socket) when event in ["new_message", "message_edited"] do
    sender_id = extract_sender_id(payload)

    if sender_id && blocked_for_recipient?(socket, sender_id) do
      {:noreply, socket}
    else
      push(socket, event, payload)
      {:noreply, socket}
    end
  end

  def handle_out(event, payload, socket)
      when event in ["reaction_added", "reaction_removed"] do
    # Pour les reactions, le sender est `userId` (camelCase, cf
    # `add_reaction` plus bas). Meme logique : si l'user qui reagit a
    # ete bloque par le destinataire, on n'envoie pas l'event.
    reactor_id = Map.get(payload, "userId") || Map.get(payload, :user_id)

    if reactor_id && blocked_for_recipient?(socket, reactor_id) do
      {:noreply, socket}
    else
      push(socket, event, payload)
      {:noreply, socket}
    end
  end

  # WHISPR-1390: kick force le close du socket cote membre cible. Sans
  # ce stop, le user reste joined et peut continuer a `handle_in` (send
  # message, edit, react) jusqu'a leave manuel. Les autres membres
  # recoivent l'event mais ne le pushent pas a leur client (pas
  # d'interet UI : ils ont deja `member_removed`).
  def handle_out("force_leave", payload, socket) do
    target_id = Map.get(payload, :user_id) || Map.get(payload, "user_id")

    if target_id == socket.assigns.user_id do
      push(socket, "force_leave", payload)
      {:stop, :shutdown, socket}
    else
      {:noreply, socket}
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

  @impl true
  def handle_info(%{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  # Cleanup automatique du typing indicator apres timeout. Sans ce untrack,
  # un client qui arrete de taper sans envoyer `typing_stop` laisse l entree
  # dans Presence indefiniment (cf WHISPR-1352).
  @impl true
  def handle_info({:stop_typing, user_id, _conversation_id}, socket) do
    Presence.stop_typing(socket, user_id)
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

    reply_to_id = Map.get(payload, "reply_to_id")

    device_id = socket.assigns[:device_id]

    message_attrs =
      %{
        conversation_id: conversation_id,
        sender_id: sender_id,
        message_type: message_type,
        content: encrypted_content,
        client_random: client_random,
        metadata: metadata
      }
      |> maybe_put(:reply_to_id, reply_to_id)
      |> maybe_put(:device_id, device_id)
      |> maybe_put("signature", Map.get(payload, "signature"))
      |> maybe_put("sender_public_key", Map.get(payload, "sender_public_key"))

    case ConversationServer.send_message(conversation_id, message_attrs) do
      {:ok, message} ->
        # Note: Broadcasting, delivery statuses, and offline notifications
        # are handled by ConversationServer

        {:reply, {:ok, %{message: serialize_message(message)}}, socket}

      {:error, {:duplicate, message}} ->
        # Return existing message as success, but don't re-notify or re-broadcast
        {:reply, {:ok, %{message: serialize_message(message)}}, socket}

      # WHISPR-1390: refus cote serveur quand le sender a une sanction
      # active sur la conversation. On retourne une raison stable au
      # client pour qu'il puisse afficher un message dedie ("vous etes
      # mute") plutot qu'une erreur generique.
      {:error, :sanctioned} ->
        {:reply, {:error, %{reason: "sanctioned"}}, socket}

      {:error, reason}
      when reason in [
             :invalid_signature,
             :missing_signature_fields,
             :invalid_key_length,
             :invalid_signature_length,
             :invalid_signature_encoding,
             :invalid_public_key_encoding,
             :untrusted_public_key,
             :verification_error
           ] ->
        {:reply, {:error, %{reason: "invalid_signature"}}, socket}

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
        payload = %{message: serialize_message(message)}

        broadcast(socket, "message_edited", payload)

        # Fanout sur le canal user:* de chaque membre pour que ConversationsListScreen
        # mette a jour le last_message meme quand la ChatScreen n est pas ouverte
        # (meme pattern que message_deleted - WHISPR-1293/1301).
        message.conversation_id
        |> Conversations.list_conversation_members()
        |> Enum.each(fn member ->
          WhisprMessagingWeb.Endpoint.broadcast(
            "user:#{member.user_id}",
            "message_edited",
            payload
          )
        end)

        {:reply, {:ok, payload}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "message_not_editable"}}, socket}
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
        payload =
          camelize_keys(%{
            message_id: message_id,
            conversation_id: message.conversation_id,
            delete_for_everyone: delete_for_everyone
          })

        broadcast(socket, "message_deleted", payload)

        # Fanout sur le canal user:* de chaque membre (uniquement delete_for_everyone)
        # pour que ConversationsListScreen recoive l event meme sans ChatScreen ouverte.
        if delete_for_everyone do
          message.conversation_id
          |> Conversations.list_conversation_members()
          |> Enum.each(fn member ->
            WhisprMessagingWeb.Endpoint.broadcast(
              "user:#{member.user_id}",
              "message_deleted",
              payload
            )
          end)
        end

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
      {:ok, _delivery_status} ->
        # Notify sender about delivery
        notify_sender_delivery_status(message_id, user_id, "delivered")
        {:reply, {:ok, %{status: "delivered"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Handle typing indicator
  def handle_in("user_typing", %{"typing" => typing}, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    ConversationServer.update_typing(conversation_id, user_id, typing)
    {:noreply, socket}
  end

  # Handle read receipt
  def handle_in("mark_read", payload, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id
    message_id = Map.get(payload, "message_id")

    ConversationServer.mark_read(conversation_id, user_id, message_id)
    {:noreply, socket}
  end

  # Handle message read confirmation
  def handle_in("message_read", %{"message_id" => message_id}, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    # Delegate to ConversationServer (async)
    ConversationServer.mark_read(conversation_id, user_id, message_id)

    # Optimistic success response
    {:reply, {:ok, %{status: "read"}}, socket}
  end

  # WHISPR-1304: symetrique a mark_read. Le client envoie
  # `{ "message_id": "..." }` pour remettre un message lu en non-lu.
  # `message_id` est obligatoire (un mark_unread sur toute la conv
  # n'a pas de sens cote produit).
  def handle_in("mark_unread", %{"message_id" => message_id}, socket)
      when is_binary(message_id) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    ConversationServer.mark_unread(conversation_id, user_id, message_id)
    {:reply, {:ok, %{status: "unread"}}, socket}
  end

  def handle_in("mark_unread", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload", details: "message_id is required"}}, socket}
  end

  # Handle typing indicators
  def handle_in("typing_start", _payload, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    ConversationServer.update_typing(conversation_id, user_id, true)
    {:noreply, socket}
  end

  def handle_in("typing_stop", _payload, socket) do
    conversation_id = socket.assigns.conversation_id
    user_id = socket.assigns.user_id

    ConversationServer.update_typing(conversation_id, user_id, false)
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
        broadcast(
          socket,
          "reaction_added",
          camelize_keys(%{
            message_id: message_id,
            user_id: user_id,
            reaction: reaction
          })
        )

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
        broadcast(
          socket,
          "reaction_removed",
          camelize_keys(%{
            message_id: message_id,
            user_id: user_id,
            reaction: reaction
          })
        )

        {:reply, {:ok, %{status: "removed"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "reaction_not_found"}}, socket}
    end
  end

  # Private functions

  defp verify_conversation_access(conversation_id, user_id) do
    # First check if conversation exists
    case Conversations.get_conversation(conversation_id) do
      {:ok, conversation} ->
        # Then check membership
        case Conversations.get_conversation_member(conversation_id, user_id) do
          %ConversationMember{is_active: true} ->
            # WHISPR-1364: pour les conv directes, on bloque le join si
            # l'un des deux a bloque l'autre. Sinon le user bloque pourrait
            # quand meme atterrir sur la chat screen et envoyer des
            # messages que l'autre voit. Pour les groupes on laisse joindre :
            # l'user reste legitimement membre, le filtre se fait au niveau
            # broadcast (handle_out).
            check_direct_block(conversation, user_id)

          _ ->
            {:error, :not_member}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Pour conv directe : on cherche l'autre membre et on demande au
  # user-service si la paire est bloquee (relation symetrique). On
  # fail-open sur erreur transitoire pour ne pas casser le messaging si
  # user-service est down.
  defp check_direct_block(%{type: "direct"} = conversation, user_id) do
    other_id =
      conversation.id
      |> Conversations.list_conversation_members()
      |> Enum.map(& &1.user_id)
      |> Enum.find(fn id -> id != user_id end)

    case other_id do
      nil ->
        {:ok, conversation}

      other ->
        case UserService.check_user_blocked(user_id, other) do
          {:ok, true} -> {:error, :blocked}
          _ -> {:ok, conversation}
        end
    end
  end

  defp check_direct_block(conversation, _user_id), do: {:ok, conversation}

  # Helpers WHISPR-1364: extraction du sender du payload broadcaste pour
  # le filtrage handle_out. Le payload est camelize_keys/1 (cf
  # `serialize_message`) donc on lit `"senderId"` cote string.
  defp extract_sender_id(%{message: %{"senderId" => sender_id}}), do: sender_id
  defp extract_sender_id(%{"message" => %{"senderId" => sender_id}}), do: sender_id
  defp extract_sender_id(%{message: %{senderId: sender_id}}), do: sender_id
  defp extract_sender_id(_), do: nil

  # Le destinataire = user assis derriere ce socket. On verifie s'il a
  # une relation de blocage avec le sender, en passant par la map cachee
  # en ETS pour ne pas hammer user-service par broadcast.
  defp blocked_for_recipient?(socket, sender_id) do
    recipient_id = socket.assigns.user_id
    conversation_id = socket.assigns.conversation_id

    blocks = Conversations.get_blocks_for_conversation(conversation_id)

    case Map.get(blocks, recipient_id) do
      nil -> false
      set -> MapSet.member?(set, sender_id)
    end
  end

  defp notify_sender_delivery_status(message_id, user_id, status) do
    case Messages.get_message_sender(message_id) do
      {:ok, sender_id} when sender_id != user_id ->
        WhisprMessagingWeb.Endpoint.broadcast(
          "user:#{sender_id}",
          "delivery_status",
          camelize_keys(%{
            message_id: message_id,
            user_id: user_id,
            status: status,
            timestamp: DateTime.utc_now()
          })
        )

      _ ->
        :ok
    end
  end

  defp safe_binary_content(nil), do: nil

  defp safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  defp safe_binary_content(content), do: to_string(content)

  defp serialize_message(%Message{} = message) do
    alias WhisprMessaging.Messages.DeliveryStatus

    base = %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      reply_to_id: message.reply_to_id,
      message_type: message.message_type,
      content: safe_binary_content(message.content),
      metadata: message.metadata,
      client_random: message.client_random,
      sent_at: message.sent_at,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      delete_for_everyone: message.delete_for_everyone,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }

    result =
      case message do
        %{delivery_statuses: statuses} when is_list(statuses) ->
          Map.put(base, :delivery_status, DeliveryStatus.compute_aggregate_status(statuses))

        _ ->
          Map.put(base, :delivery_status, "sent")
      end

    result =
      case message do
        %{reply_to: %Message{} = parent} ->
          Map.put(result, :reply_to, serialize_reply_context(parent))

        _ ->
          result
      end

    camelize_keys(result)
  end

  defp serialize_reply_context(%Message{} = parent) do
    %{
      id: parent.id,
      sender_id: parent.sender_id,
      content: safe_binary_content(parent.content),
      message_type: parent.message_type,
      is_deleted: parent.is_deleted
    }
  end

  defp serialize_reaction(reaction) do
    camelize_keys(%{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      reaction: reaction.reaction,
      inserted_at: reaction.inserted_at
    })
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
