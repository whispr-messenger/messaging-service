defmodule WhisprMessagingWeb.PageController do
  @moduledoc """
  Simple page controller for root route.
  """

  use WhisprMessagingWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
