defmodule WhisprMessagingWeb.Presence do
  @moduledoc """
  Module Presence pour tracker la présence globale des utilisateurs
  """
  use Phoenix.Presence,
    otp_app: :whispr_messaging,
    pubsub_server: WhisprMessaging.PubSub
end
