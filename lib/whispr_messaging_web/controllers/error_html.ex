defmodule WhisprMessagingWeb.ErrorHTML do
  @moduledoc """
  Renders errors as HTML (fallback for non-JSON requests).
  """

  # Fallback for all status codes — returns a plain-text body so Phoenix
  # doesn't crash when no HTML template is found.
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)
    "Error: #{status}"
  end
end
