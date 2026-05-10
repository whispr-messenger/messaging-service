defmodule WhisprMessaging.Notifications.InboxDispatcher do
  @moduledoc """
  Emits user-actionable inbox events to the Redis pubsub channel
  `whispr:notifications:inbox`.

  Two event types are handled:

    * `mention` — when a message's metadata carries a `mentions` list and at
      least one mentioned user is an active member of the conversation.

    * `reply` — when a message has a `reply_to_id` and the original sender is
      not the same as the current message's sender (no self-reply event).

  Both functions are fire-and-forget by design: Redis failures are caught and
  logged at warn level so they never block the message creation path.

  Content is end-to-end encrypted (stored as BYTEA) so mention extraction
  cannot be done with a regex on the content field. Instead the client is
  expected to send an explicit `mentions` list in `metadata`:

      %{
        "mentions" => [
          %{"user_id" => "<uuid>", "username" => "@alice"}
        ]
      }

  If `metadata["mentions"]` is absent or empty, `dispatch_mentions/2` is a
  no-op.
  """

  require Logger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Moderation.Helpers, as: ModerationHelpers

  @inbox_channel "whispr:notifications:inbox"

  @doc """
  Dispatches a `mention` event for each mentioned user who is an active member
  of the conversation.

  `members` is the list of `%ConversationMember{}` structs for the conversation
  (already fetched upstream). Passing them in avoids a redundant DB query.

  Skips:
    - mentions where `user_id` equals the sender (self-mention)
    - mentions where the mentioned user is not an active member of the
      conversation (anti-spam: strangers mentioned by someone else are silently
      ignored)
  """
  @spec dispatch_mentions(map(), [map()]) :: :ok
  def dispatch_mentions(%{metadata: metadata} = message, members) when is_map(metadata) do
    mentions = Map.get(metadata, "mentions", [])

    if is_list(mentions) and mentions != [] do
      member_ids = MapSet.new(members, & &1.user_id)
      conversation_name = conversation_name(message)

      Enum.each(mentions, fn mention ->
        dispatch_mention(message, mention, member_ids, conversation_name)
      end)
    end

    :ok
  end

  def dispatch_mentions(_message, _members), do: :ok

  @doc """
  Dispatches a `reply` event to the sender of the original message when
  `message.reply_to_id` is non-nil and the reply is not a self-reply.

  Relies on `message.reply_to` being preloaded (which `Messages.create_message/1`
  already does before calling this function).
  """
  @spec dispatch_reply(map()) :: :ok
  def dispatch_reply(%{reply_to_id: nil}), do: :ok
  def dispatch_reply(%{reply_to_id: reply_to_id}) when is_nil(reply_to_id), do: :ok

  def dispatch_reply(%{reply_to_id: _reply_to_id} = message) do
    original_sender_id = fetch_original_sender_id(message)
    dispatch_reply_event(message, original_sender_id)
  end

  def dispatch_reply(_), do: :ok

  @doc """
  Publishes a single inbox event to Redis.

  Tolerates Redis failures: logs a warning and returns `:ok` so the caller is
  never impacted.
  """
  @spec publish_event(binary(), binary(), map()) :: :ok
  def publish_event(user_id, event_type, payload) do
    envelope = %{
      "user_id" => user_id,
      "event_type" => event_type,
      "payload" => payload
    }

    case Jason.encode(envelope) do
      {:ok, json} ->
        publisher().(@inbox_channel, json)
        :ok

      {:error, reason} ->
        Logger.warning("InboxDispatcher: failed to encode event",
          user_id: user_id,
          event_type: event_type,
          reason: inspect(reason),
          domain: :inbox_dispatcher
        )

        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch_mention(message, mention, member_ids, conversation_name) do
    with mentioned_user_id when is_binary(mentioned_user_id) <- Map.get(mention, "user_id"),
         true <- mentioned_user_id != message.sender_id,
         true <- MapSet.member?(member_ids, mentioned_user_id) do
      username = Map.get(mention, "username", "")

      payload = %{
        "from_user_id" => message.sender_id,
        "from_username" => username,
        "conversation_id" => message.conversation_id,
        "message_id" => message.id,
        "preview" => build_preview(message),
        "conversation_name" => conversation_name
      }

      publish_event(mentioned_user_id, "mention", payload)
    else
      _ -> :ok
    end
  end

  defp dispatch_reply_event(_message, nil), do: :ok

  defp dispatch_reply_event(message, original_sender_id)
       when original_sender_id == message.sender_id,
       do: :ok

  defp dispatch_reply_event(message, original_sender_id) do
    sender_username = sender_username(message)

    payload = %{
      "from_user_id" => message.sender_id,
      "from_username" => sender_username,
      "conversation_id" => message.conversation_id,
      "message_id" => message.id,
      "preview" => build_preview(message)
    }

    publish_event(original_sender_id, "reply", payload)
  end

  # Resolve the original message sender. The reply_to association is preloaded
  # by Messages.create_message/1. If for any reason it is not loaded (e.g. the
  # parent message was hard-deleted between insert and preload), we fall back to
  # a targeted DB query, then silently skip on :not_found.
  defp fetch_original_sender_id(%{reply_to: %{sender_id: sender_id}})
       when is_binary(sender_id),
       do: sender_id

  defp fetch_original_sender_id(%{reply_to_id: reply_to_id}) when is_binary(reply_to_id) do
    case Messages.get_message_sender(reply_to_id) do
      {:ok, sender_id} -> sender_id
      _ -> nil
    end
  end

  defp fetch_original_sender_id(_), do: nil

  # Extracts the group name from the preloaded conversation (nil for DMs).
  defp conversation_name(%{conversation: %{type: "group", metadata: meta}})
       when is_map(meta),
       do: Map.get(meta, "name")

  defp conversation_name(_), do: nil

  # Sender username from metadata (the client may include it for display purposes).
  defp sender_username(%{metadata: meta}) when is_map(meta),
    do: Map.get(meta, "sender_username")

  defp sender_username(_), do: nil

  # The body is encrypted; we cannot slice it. We use a plaintext preview when
  # the client explicitly provides one in metadata (e.g. for search indexing),
  # otherwise fall back to nil — the notification-service renders a generic
  # "New reply" string in that case.
  defp build_preview(%{metadata: meta}) when is_map(meta) do
    case Map.get(meta, "plaintext_preview") do
      preview when is_binary(preview) -> String.slice(preview, 0, 80)
      _ -> nil
    end
  end

  defp build_preview(_), do: nil

  # Injectable publisher — identical pattern to MessagingEvents so tests can
  # swap in a capturing stub without touching Redis.
  defp publisher do
    Application.get_env(
      :whispr_messaging,
      :inbox_dispatcher_publisher,
      &ModerationHelpers.redis_publish/2
    )
  end

  # Expose for tests that want to observe member-id resolution without a DB.
  @doc false
  def member_ids_from(members), do: MapSet.new(members, & &1.user_id)

  # Helper used by Conversations context to fetch members when not already
  # available at the call site.
  @doc false
  def fetch_members(conversation_id) do
    Conversations.list_conversation_members(conversation_id)
  end
end
