defmodule WhisprMessaging.ConversationServer do
  @moduledoc """
  GenServer process for managing individual conversation state and operations.

  Each active conversation has its own GenServer process that handles:
  - Message broadcasting and delivery
  - Member presence tracking
  - Typing indicators
  - Message ordering and synchronization
  - Rate limiting and spam protection
  """

  use GenServer
  require Logger

  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessaging.Events.MessagingEvents
  alias WhisprMessaging.Moderation.Sanctions
  alias WhisprMessaging.Services.{NotificationService, UserService}
  # alias WhisprMessaging.Conversations.{Conversation, ConversationMember}
  alias WhisprMessagingWeb.{Endpoint, Presence}

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  # WHISPR-1360: timeouts explicites sur GenServer.call. Le defaut Erlang
  # est 5_000 ms : sous charge (DB lente, lock d'index, broadcast multi-membres),
  # le caller obtient {:EXIT, ...timeout} apres 5s alors que le serveur
  # continue de traiter et peut laisser un etat partiellement ecrit.
  # On dimensionne par operation pour avoir un budget realiste sans
  # bloquer la pool socket en cas de degradation.

  # Lecture seule en RAM, doit toujours repondre en quelques ms.
  # Si meme `get_state` traine, c est un signe que le GenServer est sature
  # et il vaut mieux echouer vite que d empiler les callers.
  @call_timeout_short 5_000

  # Operations DB-bound moderees (remove_member = 1 update + broadcast,
  # update_settings = 1 update + broadcast). 10s couvre un round-trip
  # Postgres lent + le passage par Phoenix.PubSub sans etre permissif.
  @call_timeout_default 10_000

  # Operations DB-bound + fanout multi-membres (send_message = insert
  # message + delivery_statuses pour N membres + broadcast PubSub +
  # publication Redis ; add_member = insert member + broadcast +
  # task system message). 15s laisse une marge pour les conversations
  # de groupe avec beaucoup de membres pendant un incident DB.
  @call_timeout_long 15_000

  # @typep conversation_state :: %{
  #          conversation_id: binary(),
  #          conversation: Conversation.t(),
  #          members: [ConversationMember.t()],
  #          active_members: MapSet.t(),
  #          typing_users: MapSet.t(),
  #          message_queue: :queue.queue(),
  #          settings: map(),
  #          last_activity: DateTime.t(),
  #          metrics: map()
  #        }

  # Client API

  @doc """
  Starts a conversation server process.
  """
  def start_link(conversation_id) do
    GenServer.start_link(__MODULE__, conversation_id, name: via_tuple(conversation_id))
  end

  @doc """
  Gets the process name via Registry.
  """
  def via_tuple(conversation_id) do
    {:via, Registry, {WhisprMessaging.ConversationRegistry, conversation_id}}
  end

  @doc """
  Sends a message through the conversation server.
  """
  def send_message(conversation_id, message_attrs) do
    GenServer.call(
      via_tuple(conversation_id),
      {:send_message, message_attrs},
      @call_timeout_long
    )
  end

  @doc """
  Adds a user to the conversation.
  """
  def add_member(conversation_id, user_id, settings \\ nil) do
    GenServer.call(
      via_tuple(conversation_id),
      {:add_member, user_id, settings},
      @call_timeout_long
    )
  end

  @doc """
  Removes a user from the conversation.
  """
  def remove_member(conversation_id, user_id) do
    GenServer.call(
      via_tuple(conversation_id),
      {:remove_member, user_id},
      @call_timeout_default
    )
  end

  @doc """
  Updates user typing status.
  """
  def update_typing(conversation_id, user_id, typing) do
    GenServer.cast(via_tuple(conversation_id), {:typing, user_id, typing})
  end

  @doc """
  Marks messages as read for a user.
  """
  def mark_read(conversation_id, user_id, message_id \\ nil) do
    GenServer.cast(via_tuple(conversation_id), {:mark_read, user_id, message_id})
  end

  @doc """
  WHISPR-1304: revert d'un mark_read sur un message specifique. Le
  reader marque "comme non-lu" un message qu'il avait deja lu, le
  serveur efface `read_at` en DB et broadcast `message_unread` aux
  autres membres (gate par le flag `read_receipts` du reader, comme
  pour mark_read).
  """
  def mark_unread(conversation_id, user_id, message_id) do
    GenServer.cast(via_tuple(conversation_id), {:mark_unread, user_id, message_id})
  end

  @doc """
  Gets conversation state for debugging.
  """
  def get_state(conversation_id) do
    GenServer.call(via_tuple(conversation_id), :get_state, @call_timeout_short)
  end

  @doc """
  Updates conversation settings.
  """
  def update_settings(conversation_id, settings) do
    GenServer.call(
      via_tuple(conversation_id),
      {:update_settings, settings},
      @call_timeout_default
    )
  end

  # GenServer Callbacks

  @impl true
  def init(conversation_id) do
    Logger.metadata(conversation_id: conversation_id, domain: :conversation_server)
    Logger.info("ConversationServer starting")

    case load_conversation_data(conversation_id) do
      {:ok, conversation, members, settings} ->
        state = %{
          conversation_id: conversation_id,
          conversation: conversation,
          members: members,
          active_members: MapSet.new(),
          typing_users: MapSet.new(),
          # WHISPR-1058: per-user timer refs so we can auto-expire a typing
          # indicator if the client never sends `typing=false` (app killed,
          # socket dropped, tab closed). Key: user_id, value: timer ref.
          typing_timers: %{},
          message_queue: :queue.new(),
          settings: settings,
          last_activity: DateTime.utc_now(),
          metrics: init_metrics()
        }

        # Schedule periodic cleanup
        schedule_cleanup()

        {:ok, state}

      {:error, reason} ->
        Logger.error("ConversationServer init failed", reason: inspect(reason))

        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, message_attrs}, _from, state) do
    case process_message(message_attrs, state) do
      {:ok, message, new_state} ->
        # Broadcast message to all channels
        broadcast_message(message, new_state)

        # Notify offline members
        notify_offline_members(message, new_state)

        # Update activity timestamp
        updated_state = %{new_state | last_activity: DateTime.utc_now()}

        {:reply, {:ok, message}, updated_state}

      {:error, reason} ->
        Logger.warning("Message processing failed", reason: inspect(reason))

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:add_member, user_id, settings}, _from, state) do
    case add_member_to_conversation(user_id, settings, state) do
      {:ok, member, new_state} ->
        # Broadcast member addition
        broadcast_member_added(member, new_state)

        # Create system message
        create_member_joined_message(user_id, new_state)

        {:reply, {:ok, member}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_member, user_id}, _from, state) do
    case remove_member_from_conversation(user_id, state) do
      {:ok, new_state} ->
        # Broadcast member removal
        broadcast_member_removed(user_id, new_state)

        # Create system message
        create_member_left_message(user_id, new_state)

        {:reply, {:ok, user_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_settings, settings}, _from, state) do
    case update_conversation_settings(settings, state) do
      {:ok, new_state} ->
        # Broadcast settings update
        broadcast_settings_updated(settings, new_state)

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    safe_state = %{
      conversation_id: state.conversation_id,
      member_count: length(state.members),
      active_member_count: MapSet.size(state.active_members),
      typing_user_count: MapSet.size(state.typing_users),
      message_queue_size: :queue.len(state.message_queue),
      last_activity: state.last_activity,
      metrics: state.metrics
    }

    {:reply, safe_state, state}
  end

  @impl true
  def handle_cast({:typing, user_id, typing}, state) do
    # WHISPR-1058: maintain a per-user watchdog so a zombie `typing=true`
    # (client died mid-session) auto-expires and the indicator clears on
    # the other side.
    cleared_timers = cancel_typing_timer(state.typing_timers, user_id)

    new_typing_timers =
      if typing do
        # Reset the watchdog on every new `typing=true` — the client will
        # re-send it periodically as long as the user is actually typing.
        Map.put(cleared_timers, user_id, schedule_typing_timeout(user_id))
      else
        cleared_timers
      end

    new_state =
      state
      |> Map.put(:typing_timers, new_typing_timers)
      |> update_typing_status_in(user_id, typing)

    # Broadcast typing status
    broadcast_typing_status(user_id, typing, new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:mark_read, user_id, message_id}, state) do
    # Update read status in database
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      if message_id do
        Messages.mark_message_read(message_id, user_id)
      else
        Messages.mark_conversation_read(state.conversation_id, user_id)
      end

      # Always update last_read_at on the conversation member so that
      # the unread_count query (messages WHERE sent_at > last_read_at)
      # returns the correct count on subsequent fetches.
      case Conversations.get_conversation_member(state.conversation_id, user_id) do
        %{is_active: true} = member ->
          Conversations.mark_member_read(member)

        _ ->
          :ok
      end
    end)

    # WHISPR-1304: gating WhatsApp punitive. On consulte le flag
    # `read_receipts` du reader cote user-service avant de broadcast.
    # Si l'utilisateur les a desactives -> on ecrit read_at en DB
    # (pour son propre badge / unread_count) mais on skip le broadcast
    # vers les autres membres. Sur erreur transitoire on fail-open
    # (broadcast quand meme): une indispo de user-service ne doit pas
    # casser la fonctionnalite pour les users qui l'ont activee.
    #
    # WHISPR-1315: le check HTTP `read_receipts_allowed?` peut bloquer
    # jusqu a 5s sur round-trip user-service. On l execute dans un Task
    # pour ne pas bloquer le GenServer (qui serialise tous les casts de
    # la conversation).
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      if read_receipts_allowed?(user_id) do
        broadcast_read_receipt(user_id, message_id, state)
      else
        Logger.debug("message_read broadcast skipped (reader privacy)",
          user_id: user_id,
          conversation_id: state.conversation_id
        )
      end
    end)

    # WHISPR-1109 follow-up: decrement the reader's badge in notification-service.
    MessagingEvents.publish_message_read(state.conversation_id, user_id, message_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:mark_unread, user_id, message_id}, state) do
    # WHISPR-1304: marquer comme non-lu cote backend = revert de la
    # row delivery_status (read_at -> nil) + rewind `last_read_at`
    # juste avant le sent_at du message + broadcast `message_unread`
    # symetrique a mark_read pour que les autres membres et les autres
    # devices du user remettent l'item en "unread" dans leur UI.
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      Messages.mark_unread(message_id, user_id)
    end)

    # Meme gating privacy que mark_read: si le user a desactive ses
    # read_receipts, on ne signale pas non plus le mark_unread.
    # WHISPR-1315: meme reason que mark_read, on sort le check HTTP
    # du GenServer.
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      if read_receipts_allowed?(user_id) do
        broadcast_unread_receipt(user_id, message_id, state)
      else
        Logger.debug("message_unread broadcast skipped (reader privacy)",
          user_id: user_id,
          conversation_id: state.conversation_id
        )
      end
    end)

    {:noreply, state}
  end

  defp read_receipts_allowed?(user_id) do
    case UserService.get_privacy_settings(user_id) do
      {:ok, %{read_receipts: false}} -> false
      # fail-open : sur error transitoire ou champ absent, on broadcast
      # comme avant le gating WHISPR-1304.
      _ -> true
    end
  end

  # WHISPR-1058: watchdog fired — the client never sent `typing=false`.
  # Clear the indicator as if a stop event had come in, but only if the
  # user is still listed (they might have sent a legitimate stop that
  # cancelled the timer milliseconds earlier).
  @impl true
  def handle_info({:typing_timeout, user_id}, state) do
    if MapSet.member?(state.typing_users, user_id) do
      new_state =
        state
        |> Map.update!(:typing_timers, &Map.delete(&1, user_id))
        |> update_typing_status_in(user_id, false)

      broadcast_typing_status(user_id, false, new_state)

      {:noreply, new_state}
    else
      {:noreply, Map.update!(state, :typing_timers, &Map.delete(&1, user_id))}
    end
  end

  def handle_info(:cleanup, state) do
    new_state = perform_cleanup(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  def handle_info({:member_joined, user_id}, state) do
    new_active_members = MapSet.put(state.active_members, user_id)
    new_state = %{state | active_members: new_active_members}

    Logger.debug("Member joined", user_id: user_id)
    {:noreply, new_state}
  end

  def handle_info({:member_left, user_id}, state) do
    new_active_members = MapSet.delete(state.active_members, user_id)
    new_typing_users = MapSet.delete(state.typing_users, user_id)
    # WHISPR-1058: cancel the typing watchdog too, otherwise we'd end up
    # sending a {:typing_timeout, user_id} message for a user that already
    # left.
    new_typing_timers = cancel_typing_timer(state.typing_timers, user_id)

    new_state = %{
      state
      | active_members: new_active_members,
        typing_users: new_typing_users,
        typing_timers: new_typing_timers
    }

    Logger.debug("Member left", user_id: user_id)
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message", msg: inspect(msg))
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("ConversationServer terminating", reason: inspect(reason))

    # The Registry will be automatically cleaned up when the process exits
    :ok
  end

  # Private Functions

  defp load_conversation_data(conversation_id) do
    with {:ok, conversation} <- Conversations.get_conversation(conversation_id),
         members <- Conversations.list_conversation_members(conversation_id),
         {:ok, settings} <- Conversations.get_conversation_settings(conversation_id) do
      {:ok, conversation, members, settings.settings}
    end
  end

  defp process_message(message_attrs, state) do
    # WHISPR-1390: verifie sanction active sur reception WS pour eviter
    # bypass via socket deja etabli. Sans ce check, un user mute /
    # shadow_restrict peut continuer a envoyer des messages tant qu'il
    # ne quitte pas le canal (le check sanction n'est sinon fait qu'au
    # join via verify_conversation_access).
    sender_id = message_attrs[:sender_id] || message_attrs["sender_id"]

    with :ok <- check_sender_not_sanctioned(state.conversation_id, sender_id),
         {:ok, message} <- Messages.create_message(message_attrs) do
      # Create delivery statuses
      Messages.create_delivery_statuses_for_conversation(
        message.id,
        state.conversation_id,
        message.sender_id
      )

      # Update metrics
      new_metrics = update_message_metrics(state.metrics)
      new_state = %{state | metrics: new_metrics}

      {:ok, message, new_state}
    else
      {:error, :sanctioned} = err ->
        err

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_message_creation_error(changeset, message_attrs)

      {:error, reason} when is_atom(reason) ->
        # Signature verification errors (e.g. :invalid_signature,
        # :missing_signature_fields, :invalid_key_length, etc.)
        {:error, reason}
    end
  end

  # WHISPR-1390: refuse l'envoi si le sender a une sanction active
  # (mute / shadow_restrict / kick) sur cette conversation. Le check
  # est volontairement strict : toute sanction active bloque l'envoi
  # cote serveur, peu importe le type. fail-closed sur erreur DB pour
  # ne pas creer de bypass silencieux.
  defp check_sender_not_sanctioned(_conversation_id, nil), do: :ok

  defp check_sender_not_sanctioned(conversation_id, sender_id) do
    case Sanctions.active_sanction_for(conversation_id, sender_id) do
      nil ->
        :ok

      sanction ->
        Logger.info("Message rejete: sanction active",
          sanction_type: sanction.type,
          conversation_id: conversation_id,
          sender_id: sender_id,
          domain: :moderation
        )

        {:error, :sanctioned}
    end
  end

  defp handle_message_creation_error(changeset, message_attrs) do
    if duplicate_message_error?(changeset) do
      sender_id = message_attrs[:sender_id] || message_attrs["sender_id"]
      client_random = message_attrs[:client_random] || message_attrs["client_random"]

      case Messages.get_message_by_sender_and_random(sender_id, client_random) do
        {:ok, existing_message} ->
          {:error, {:duplicate, WhisprMessaging.Repo.preload(existing_message, :reply_to)}}

        _ ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp duplicate_message_error?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, opts}} ->
      opts[:constraint_name] == "messages_sender_id_client_random_index"
    end)
  end

  defp add_member_to_conversation(user_id, settings, state) do
    case Conversations.add_conversation_member(state.conversation_id, user_id, settings) do
      {:ok, member} ->
        new_members = [member | state.members]
        new_state = %{state | members: new_members}
        {:ok, member, new_state}

      error ->
        error
    end
  end

  defp remove_member_from_conversation(user_id, state) do
    case Conversations.remove_conversation_member(state.conversation_id, user_id) do
      {:ok, _member} ->
        new_members = Enum.reject(state.members, &(&1.user_id == user_id))
        new_active_members = MapSet.delete(state.active_members, user_id)
        new_typing_users = MapSet.delete(state.typing_users, user_id)
        # WHISPR-1058: cancel the watchdog so the removed member doesn't
        # keep getting auto-expired after they're gone.
        new_typing_timers = cancel_typing_timer(state.typing_timers, user_id)

        new_state = %{
          state
          | members: new_members,
            active_members: new_active_members,
            typing_users: new_typing_users,
            typing_timers: new_typing_timers
        }

        {:ok, new_state}

      error ->
        error
    end
  end

  defp update_conversation_settings(settings, state) do
    case Conversations.update_conversation_settings(state.conversation.id, settings) do
      {:ok, _updated_settings} ->
        new_state = %{state | settings: Map.merge(state.settings, settings)}
        {:ok, new_state}

      error ->
        error
    end
  end

  defp update_typing_status(user_id, typing, state) do
    new_typing_users =
      if typing do
        MapSet.put(state.typing_users, user_id)
      else
        MapSet.delete(state.typing_users, user_id)
      end

    %{state | typing_users: new_typing_users}
  end

  # Same body as update_typing_status/3 but invoked through the pipe-friendly
  # argument order needed by the WHISPR-1058 handler. Kept separate so the
  # original private function stays untouched for other call sites.
  defp update_typing_status_in(state, user_id, typing),
    do: update_typing_status(user_id, typing, state)

  defp broadcast_message(message, state) do
    serialized = serialize_message(message)

    # Broadcast to the conversation channel (for users with ChatScreen open)
    Endpoint.broadcast("conversation:#{state.conversation_id}", "new_message", %{
      message: serialized
    })

    # Broadcast to each member's user channel (for ConversationsListScreen / background updates)
    Enum.each(state.members, fn member ->
      if member.user_id != message.sender_id do
        Endpoint.broadcast("user:#{member.user_id}", "new_message", %{
          message: serialized
        })
      end
    end)

    # Redis publish to notification-service is owned by `Messages.create_message`
    # (via `publish_new_message_async/1`) — calling it again here used to
    # produce duplicate events / double push notifications.
  end

  defp notify_offline_members(message, state) do
    # Get all conversation members from state
    member_ids = Enum.map(state.members, & &1.user_id)

    # Get online users from Presence
    # Presence keys are strings (user_ids)
    presence_list = Presence.list("conversation:#{state.conversation_id}")
    online_user_ids = Map.keys(presence_list)

    # Calculate offline users
    offline_user_ids = member_ids -- online_user_ids
    # Remove sender from offline list if present
    offline_user_ids = List.delete(offline_user_ids, message.sender_id)

    unless Enum.empty?(offline_user_ids) do
      Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
        NotificationService.queue_push_notifications(offline_user_ids, message)
      end)
    end
  end

  defp broadcast_member_added(member, state) do
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "member_added",
      camelize_keys(%{
        member: serialize_member(member),
        conversation_id: state.conversation_id
      })
    )
  end

  defp broadcast_member_removed(user_id, state) do
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "member_removed",
      camelize_keys(%{
        user_id: user_id,
        conversation_id: state.conversation_id
      })
    )

    # WHISPR-1390: force le close du socket du membre kick. Le channel
    # intercept l'event et appelle {:stop, :shutdown, socket} si le
    # user assis derriere le socket est la cible. Sans ca, le membre
    # reste joined apres remove_member et peut continuer a envoyer
    # des messages via le socket deja etabli.
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "force_leave",
      %{user_id: user_id, reason: "kicked"}
    )
  end

  defp broadcast_typing_status(user_id, typing, state) do
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "user_typing",
      camelize_keys(%{
        user_id: user_id,
        typing: typing,
        conversation_id: state.conversation_id
      })
    )
  end

  defp broadcast_read_receipt(user_id, message_id, state) do
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "message_read",
      camelize_keys(%{
        user_id: user_id,
        message_id: message_id,
        conversation_id: state.conversation_id,
        timestamp: DateTime.utc_now()
      })
    )
  end

  # WHISPR-1304: broadcast `message_unread` symetrique a `message_read`.
  # Diffuse sur le topic conversation et fanout sur le canal user:* de
  # chaque membre pour que ConversationsListScreen remette l'item en
  # "unread" meme quand ChatScreen n'est pas ouverte (meme pattern
  # que la suppression dans WHISPR-1301).
  defp broadcast_unread_receipt(user_id, message_id, state) do
    payload =
      camelize_keys(%{
        user_id: user_id,
        message_id: message_id,
        conversation_id: state.conversation_id,
        timestamp: DateTime.utc_now()
      })

    Endpoint.broadcast("conversation:#{state.conversation_id}", "message_unread", payload)

    # On exclut le reader du fanout user:*, il vient juste de cliquer mark_unread
    # sur son device et recoit deja l event via le topic conversation:*.
    # Sans ca son badge blink (event recu 2x).
    Enum.each(state.members, fn member ->
      if member.user_id != user_id do
        Endpoint.broadcast("user:#{member.user_id}", "message_unread", payload)
      end
    end)
  end

  defp broadcast_settings_updated(settings, state) do
    Endpoint.broadcast(
      "conversation:#{state.conversation_id}",
      "settings_updated",
      camelize_keys(%{
        settings: settings,
        conversation_id: state.conversation_id
      })
    )
  end

  defp create_member_joined_message(user_id, state) do
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      Messages.create_system_message(
        state.conversation_id,
        "User joined conversation",
        %{"action" => "member_joined", "user_id" => user_id}
      )
    end)
  end

  defp create_member_left_message(user_id, state) do
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      Messages.create_system_message(
        state.conversation_id,
        "User left conversation",
        %{"action" => "member_left", "user_id" => user_id}
      )
    end)
  end

  defp safe_binary_content(nil), do: nil

  defp safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  defp safe_binary_content(content), do: to_string(content)

  @doc false
  def serialize_message(message) do
    alias WhisprMessaging.Messages.DeliveryStatus
    alias WhisprMessaging.Messages.Message

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
      delete_for_everyone: message.delete_for_everyone
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
          Map.put(result, :reply_to, %{
            id: parent.id,
            sender_id: parent.sender_id,
            content: safe_binary_content(parent.content),
            message_type: parent.message_type,
            is_deleted: parent.is_deleted
          })

        _ ->
          result
      end

    camelize_keys(result)
  end

  defp serialize_member(member) do
    camelize_keys(%{
      id: member.id,
      conversation_id: member.conversation_id,
      user_id: member.user_id,
      settings: member.settings,
      joined_at: member.joined_at,
      last_read_at: member.last_read_at,
      is_active: member.is_active
    })
  end

  defp init_metrics do
    %{
      messages_sent: 0,
      members_added: 0,
      members_removed: 0,
      typing_events: 0,
      last_reset: DateTime.utc_now()
    }
  end

  defp update_message_metrics(metrics) do
    %{metrics | messages_sent: metrics.messages_sent + 1}
  end

  defp perform_cleanup(state) do
    # Clean up old typing indicators (older than 30 seconds)
    _now = System.system_time(:second)
    # This would normally involve checking timestamps, but for simplicity
    # we'll just clear typing users if they've been typing too long
    new_state = %{state | typing_users: MapSet.new()}

    # Update last activity if conversation has been idle
    if DateTime.diff(DateTime.utc_now(), state.last_activity, :minute) > 5 do
      Logger.debug("Conversation idle for 5+ minutes")
    end

    new_state
  end

  defp schedule_cleanup do
    # Every 30 seconds
    Process.send_after(self(), :cleanup, 30_000)
  end

  # WHISPR-1058: how long a single `typing=true` stays valid before the
  # server auto-expires it. Must be ≥ the client's keep-alive interval
  # (the mobile app re-sends typing every ~3s as long as the user types).
  # 6s gives room for one missed ping without flapping the indicator off
  # during a legitimately-typing burst.
  @typing_timeout_ms 6_000

  defp schedule_typing_timeout(user_id) do
    Process.send_after(self(), {:typing_timeout, user_id}, @typing_timeout_ms)
  end

  defp cancel_typing_timer(typing_timers, user_id) do
    case Map.get(typing_timers, user_id) do
      nil ->
        typing_timers

      ref ->
        Process.cancel_timer(ref)
        Map.delete(typing_timers, user_id)
    end
  end
end
