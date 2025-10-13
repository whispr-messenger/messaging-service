defmodule WhisprMessagingWeb.Router do
  @moduledoc """
  Phoenix router for WhisprMessaging web interface.

  Defines HTTP routes for the messaging service API and health endpoints.
  """

  use WhisprMessagingWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WhisprMessagingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", WhisprMessagingWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Health check endpoints (no authentication required)
  scope "/", WhisprMessagingWeb do
    get "/health", HealthController, :health
    get "/health/ready", HealthController, :ready
    get "/health/live", HealthController, :live
  end

  scope "/api/v1", WhisprMessagingWeb do
    pipe_through :api

    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    get "/conversations/:id/messages", MessageController, :index
    post "/conversations/:id/messages", MessageController, :create
    get "/messages/:id", MessageController, :show
    put "/messages/:id", MessageController, :update
    delete "/messages/:id", MessageController, :delete
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:whispr_messaging, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WhisprMessagingWeb.Telemetry
    end
  end
end
