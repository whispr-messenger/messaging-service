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
    # TODO: Implement actual gRPC call
    # For now, just log the notifications
    Logger.debug("Queuing push notifications for users: #{inspect(user_ids)} for message: #{message.id}")
    {:ok, :queued}
  end
end
