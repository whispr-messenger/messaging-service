defmodule WhisprMessagingWeb.ConversationPresence do
  @moduledoc """
  Module Presence pour tracker la présence dans les conversations individuelles
  """
  use Phoenix.Presence,
    otp_app: :whispr_messaging,
    pubsub_server: WhisprMessaging.PubSub
end
