defmodule WhisprMessagingWeb.ErrorJSON do
  @moduledoc """
  JSON error response handler for the WhisprMessaging API.

  Translates error atoms and exceptions into JSON responses.
  """

  import Plug.Conn, only: [get_resp_header: 2]

  @doc """
  Render error response.
  """
  def render(template, _assigns)

  def render("500.json", _assigns) do
    %{
      errors: %{
        detail: "Internal server error"
      }
    }
  end

  def render("404.json", _assigns) do
    %{
      errors: %{
        detail: "Not found"
      }
    }
  end

  def render("400.json", _assigns) do
    %{
      errors: %{
        detail: "Bad request"
      }
    }
  end
end
