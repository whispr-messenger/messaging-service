defmodule WhisprMessaging.Events.MessagingEvents do
  @moduledoc """
  Fire-and-forget Redis pub/sub events consumed by notification-service
  to keep unread badges in sync.

  Two channels:

    * `whispr:messaging:new_message` — emitted every time a message is
      persisted in a conversation. notification-service increments the
      badge for each `target_user_ids` entry.

    * `whispr:messaging:message_read` — emitted when a message (or a
      whole conversation) is marked as read. notification-service
      decrements the badge for `user_id`.

  Redis failures are caught and logged; they must never crash the caller.
  """

  require Logger

  alias WhisprMessaging.Moderation.Helpers, as: ModerationHelpers

  @new_message_channel "whispr:messaging:new_message"
  @message_read_channel "whispr:messaging:message_read"

  @doc """
  Publishes a `new_message` event for every recipient except the sender.

  `members` is the list of conversation members (maps or structs with a
  `:user_id` field). Empty target list short-circuits without touching
  Redis so direct-conversation edge cases stay cheap.
  """
  @spec publish_new_message(map(), [map()], keyword()) :: :ok
  def publish_new_message(message, members, opts \\ []) do
    target_user_ids =
      members
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&(&1 == message.sender_id))
      |> Enum.uniq()

    if target_user_ids == [] do
      :ok
    else
      payload = %{
        "conversation_id" => message.conversation_id,
        "message_id" => message.id,
        "sender_id" => message.sender_id,
        "target_user_ids" => target_user_ids,
        "count" => Keyword.get(opts, :count, 1)
      }

      publish_json(@new_message_channel, payload, message.conversation_id)
    end
  end

  @doc """
  Publishes a `message_read` event for a single reader.

  `message_id` may be `nil` when the whole conversation is marked read.
  `count` defaults to 1 but can be the number of messages flipped to
  "read" so the badge decrements correctly in bulk cases.
  """
  @spec publish_message_read(binary(), binary(), binary() | nil, keyword()) :: :ok
  def publish_message_read(conversation_id, user_id, message_id, opts \\ []) do
    payload = %{
      "conversation_id" => conversation_id,
      "user_id" => user_id,
      "message_id" => message_id,
      "count" => Keyword.get(opts, :count, 1)
    }

    publish_json(@message_read_channel, payload, conversation_id)
  end

  defp publish_json(channel, payload, conversation_id) do
    case Jason.encode(payload) do
      {:ok, json} ->
        publisher().(channel, json)
        :ok

      {:error, reason} ->
        Logger.error("Failed to encode Redis pubsub payload",
          reason: inspect(reason),
          channel: channel,
          conversation_id: conversation_id,
          domain: :pubsub
        )

        :ok
    end
  end

  # The publisher is injectable via application config so tests can swap
  # it for a capturing stub without needing a live Redis. The default
  # wires through the shared moderation helper which already rescues
  # Redix crashes.
  defp publisher do
    Application.get_env(
      :whispr_messaging,
      :messaging_events_publisher,
      &ModerationHelpers.redis_publish/2
    )
  end
end
