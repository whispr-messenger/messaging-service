defmodule WhisprMessaging.Services.NotificationService do
  @moduledoc """
  Interface for interacting with the Notification Service via gRPC.
  Currently a stub implementation.
  """

  require Logger

  @doc """
  Queues push notifications for offline users.
  """
  def queue_push_notifications(user_ids, message) do
    # Stub: logs until gRPC integration with notification service is done
    # For now, just log the notifications
    Logger.debug("Queuing push notifications",
      user_count: length(user_ids),
      message_id: message.id,
      domain: :notifications
    )

    {:ok, :queued}
  end
end
