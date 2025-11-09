defmodule WhisprMessagingWeb.HealthController do
  @moduledoc """
  Health check endpoint for the WhisprMessaging service.

  This controller provides a simple health check endpoint that confirms
  the API is running and responsive.
  """

  use WhisprMessagingWeb, :controller

  @doc """
  Health check endpoint.

  Returns a 200 OK response to confirm the service is healthy.
  """
  def check(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "whispr-messaging",
      timestamp: DateTime.utc_now()
    })
  end
end
