defmodule WhisprMessagingWeb.Presence do
  @moduledoc """
  Phoenix Presence implementation for tracking user online status
  and presence in conversations.

  Provides real-time presence tracking with automatic conflict resolution
  and efficient state synchronization across distributed nodes.
  """

  use Phoenix.Presence,
    otp_app: :whispr_messaging,
    pubsub_server: WhisprMessaging.PubSub

  require Logger

  alias WhisprMessagingWeb.PresenceHelpers

  @doc """
  Tracks a user's presence in a specific context (conversation or global).
  """
  def track_user(socket, user_id, meta \\ %{}) do
    default_meta = %{
      online_at: System.system_time(:second),
      status: "online"
    }

    meta = Map.merge(default_meta, meta)
    track(socket, user_id, meta)
  end

  @doc """
  Updates a user's presence metadata.
  """
  def update_user(socket, user_id, meta) do
    update(socket, user_id, meta)
  end

  @doc """
  Gets all users currently present in a topic.
  """
  def list_users(topic) do
    list(topic)
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      %{
        user_id: user_id,
        status: get_current_status(metas),
        online_at: get_latest_online_at(metas),
        device_count: length(metas)
      }
    end)
  end

  @doc """
  Checks if a user is currently online in any context.
  """
  def user_online?(user_id) do
    # Check global user presence
    case get_by_key("user:#{user_id}", user_id) do
      [] -> false
      _presences -> true
    end
  end

  @doc """
  Gets a user's current status across all their sessions.
  """
  def get_user_status(user_id) do
    case get_by_key("user:#{user_id}", user_id) do
      [] ->
        "offline"

      %{metas: metas} ->
        get_current_status(metas)
    end
  end

  @doc """
  Gets all users present in a specific conversation.
  """
  def get_conversation_users(conversation_id) do
    list_users("conversation:#{conversation_id}")
  end

  @doc """
  Tracks typing indicators with automatic cleanup.
  """
  def track_typing(socket, user_id, conversation_id) do
    meta = %{
      typing: true,
      conversation_id: conversation_id,
      started_at: System.system_time(:second)
    }

    track(socket, "typing:#{user_id}", meta)

    # Schedule automatic cleanup after 10 seconds
    Process.send_after(self(), {:stop_typing, user_id, conversation_id}, 10_000)
  end

  @doc """
  Stops typing indicator for a user.
  """
  def stop_typing(socket, user_id) do
    untrack(socket, "typing:#{user_id}")
  end

  @doc """
  Gets active typing users in a conversation.
  """
  def get_typing_users(conversation_id) do
    list("conversation:#{conversation_id}")
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "typing:") end)
    |> Enum.map(fn {"typing:" <> user_id, %{metas: metas}} ->
      %{
        user_id: user_id,
        started_at: get_latest_typing_start(metas)
      }
    end)
    |> Enum.filter(fn %{started_at: started_at} ->
      # Filter out typing indicators older than 10 seconds
      System.system_time(:second) - started_at < 10
    end)
  end

  # Phoenix.Presence callbacks

  @doc """
  Callback invoked when presence state changes.
  Used for custom business logic on presence events.
  """
  def fetch(_topic, presences) do
    # Add custom user information to presence data
    _user_ids =
      presences
      |> Map.keys()
      |> Enum.filter(&(!String.starts_with?(&1, "typing:")))

    # This could be extended to fetch user profiles, last seen times, etc.
    # For now, we just return the basic presence data
    for {key, %{metas: metas}} <- presences, into: %{} do
      {key, %{metas: enrich_metas(metas, key)}}
    end
  end

  # Private helper functions

  defp get_current_status(metas), do: PresenceHelpers.current_status(metas)
  defp get_latest_online_at(metas), do: PresenceHelpers.latest_online_at(metas)
  defp get_latest_typing_start(metas), do: PresenceHelpers.latest_typing_start(metas)
  defp enrich_metas(metas, user_id), do: PresenceHelpers.enrich_metas(metas, user_id)

  # GenServer callbacks for cleanup tasks

  def handle_info({:stop_typing, user_id, conversation_id}, state) do
    # Clean up stale typing indicators
    Logger.debug("Auto-stopping typing indicator",
      user_id: user_id,
      conversation_id: conversation_id,
      domain: :presence
    )

    # This would be handled by the channel process that started the typing
    # The message is mainly for logging and monitoring
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
