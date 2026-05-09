defmodule WhisprMessaging.Services.NotificationService do
  @moduledoc """
  Facade pour parler a notification-service en gRPC.
  Stub temporaire en attendant l'integration reelle.
  """

  require Logger

  @doc """
  Met en file d'attente des push notifications pour les users offline.
  """
  def queue_push_notifications(user_ids, message) do
    # stub : on log juste tant que la couche gRPC n'est pas branchee
    Logger.debug("Queuing push notifications",
      user_count: length(user_ids),
      message_id: message.id,
      domain: :notifications
    )

    {:ok, :queued}
  end
end
