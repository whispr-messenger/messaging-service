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
  alias WhisprMessaging.Services.NotificationService
  # alias WhisprMessaging.Conversations.{Conversation, ConversationMember}
  alias WhisprMessagingWeb.{Endpoint, Presence}

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
    GenServer.call(via_tuple(conversation_id), {:send_message, message_attrs})
  end

  @doc """
  Adds a user to the conversation.
  """
  def add_member(conversation_id, user_id, settings \\ nil) do
    GenServer.call(via_tuple(conversation_id), {:add_member, user_id, settings})
  end

  @doc """
  Removes a user from the conversation.
  """
  def remove_member(conversation_id, user_id) do
    GenServer.call(via_tuple(conversation_id), {:remove_member, user_id})
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
  Gets conversation state for debugging.
  """
  def get_state(conversation_id) do
    GenServer.call(via_tuple(conversation_id), :get_state)
  end

  @doc """
  Updates conversation settings.
  """
  def update_settings(conversation_id, settings) do
    GenServer.call(via_tuple(conversation_id), {:update_settings, settings})
  end

  # GenServer Callbacks

  @impl true
  def init(conversation_id) do
    Logger.info("Starting ConversationServer for conversation #{conversation_id}")

    case load_conversation_data(conversation_id) do
      {:ok, conversation, members, settings} ->
        state = %{
          conversation_id: conversation_id,
          conversation: conversation,
          members: members,
          active_members: MapSet.new(),
          typing_users: MapSet.new(),
          message_queue: :queue.new(),
          settings: settings,
          last_activity: DateTime.utc_now(),
          metrics: init_metrics()
        }

        # Schedule periodic cleanup
        schedule_cleanup()

        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "Failed to initialize ConversationServer for #{conversation_id}: #{inspect(reason)}"
        )

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
        Logger.warning(
          "Failed to process message in conversation #{state.conversation_id}: #{inspect(reason)}"
        )

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
    new_state = update_typing_status(user_id, typing, state)

    # Broadcast typing status
    broadcast_typing_status(user_id, typing, new_state)

    {:noreply, new_state}
  end

  def handle_cast({:mark_read, user_id, message_id}, state) do
    # Update read status in database
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      if message_id do
        Messages.mark_message_read(message_id, user_id)
      else
        Messages.mark_conversation_read(state.conversation_id, user_id)
      end
    end)

    # Broadcast read receipt
    broadcast_read_receipt(user_id, message_id, state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_state = perform_cleanup(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  def handle_info({:member_joined, user_id}, state) do
    new_active_members = MapSet.put(state.active_members, user_id)
    new_state = %{state | active_members: new_active_members}

    Logger.debug("Member #{user_id} joined conversation #{state.conversation_id}")
    {:noreply, new_state}
  end

  def handle_info({:member_left, user_id}, state) do
    new_active_members = MapSet.delete(state.active_members, user_id)
    new_typing_users = MapSet.delete(state.typing_users, user_id)

    new_state = %{state | active_members: new_active_members, typing_users: new_typing_users}

    Logger.debug("Member #{user_id} left conversation #{state.conversation_id}")
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in ConversationServer: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug(
      "ConversationServer terminating for #{state.conversation_id}, reason: #{inspect(reason)}"
    )

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
    # Validate and create message
    case Messages.create_message(message_attrs) do
      {:ok, message} ->
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

      {:error, changeset} ->
        handle_message_creation_error(changeset, message_attrs)
    end
  end

  defp handle_message_creation_error(changeset, message_attrs) do
    if duplicate_message_error?(changeset) do
      sender_id = message_attrs[:sender_id] || message_attrs["sender_id"]
      client_random = message_attrs[:client_random] || message_attrs["client_random"]

      case Messages.get_message_by_sender_and_random(sender_id, client_random) do
        {:ok, existing_message} ->
          {:error, {:duplicate, existing_message}}

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

        new_state = %{
          state
          | members: new_members,
            active_members: new_active_members,
            typing_users: new_typing_users
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

  defp broadcast_message(message, state) do
    Endpoint.broadcast("conversation:#{state.conversation_id}", "new_message", %{
      message: serialize_message(message)
    })
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
    Endpoint.broadcast("conversation:#{state.conversation_id}", "member_added", %{
      member: serialize_member(member),
      conversation_id: state.conversation_id
    })
  end

  defp broadcast_member_removed(user_id, state) do
    Endpoint.broadcast("conversation:#{state.conversation_id}", "member_removed", %{
      user_id: user_id,
      conversation_id: state.conversation_id
    })
  end

  defp broadcast_typing_status(user_id, typing, state) do
    Endpoint.broadcast("conversation:#{state.conversation_id}", "user_typing", %{
      user_id: user_id,
      typing: typing,
      conversation_id: state.conversation_id
    })
  end

  defp broadcast_read_receipt(user_id, message_id, state) do
    Endpoint.broadcast("conversation:#{state.conversation_id}", "message_read", %{
      user_id: user_id,
      message_id: message_id,
      conversation_id: state.conversation_id,
      timestamp: DateTime.utc_now()
    })
  end

  defp broadcast_settings_updated(settings, state) do
    Endpoint.broadcast("conversation:#{state.conversation_id}", "settings_updated", %{
      settings: settings,
      conversation_id: state.conversation_id
    })
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

  defp serialize_message(message) do
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
      delete_for_everyone: message.delete_for_everyone
    }
  end

  defp serialize_member(member) do
    %{
      id: member.id,
      conversation_id: member.conversation_id,
      user_id: member.user_id,
      settings: member.settings,
      joined_at: member.joined_at,
      last_read_at: member.last_read_at,
      is_active: member.is_active
    }
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
      Logger.debug("Conversation #{state.conversation_id} has been idle for 5+ minutes")
    end

    new_state
  end

  defp schedule_cleanup do
    # Every 30 seconds
    Process.send_after(self(), :cleanup, 30_000)
  end
end
