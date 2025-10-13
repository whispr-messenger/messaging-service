defmodule WhisprMessagingWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the messaging service.

  This module will be expanded as the UI components are developed.
  For now, it serves as a placeholder to satisfy compilation requirements.
  """

  use Phoenix.Component

  @doc """
  Renders a simple error message.
  """
  attr :message, :string, required: true

  def error(assigns) do
    ~H"""
    <div class="alert alert-danger">
      <%= @message %>
    </div>
    """
  end
end
