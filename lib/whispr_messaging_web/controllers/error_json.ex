defmodule WhisprMessagingWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by Phoenix when an error occurs and the accept header
  is set to JSON. It renders errors in a standardized JSON format.
  """

  @doc """
  Renders a generic error response.
  """
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
