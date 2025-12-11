defmodule WhisprMessagingWeb.Router do
  @moduledoc """
  Phoenix router for WhisprMessaging web interface.

  Defines HTTP routes for the messaging service API and health endpoints.
  """

  use WhisprMessagingWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WhisprMessagingWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/api/swagger" do
    forward "/", PhoenixSwagger.Plug.SwaggerUI,
      otp_app: :whispr_messaging,
      swagger_file: "swagger.json"
  end

  scope "/", WhisprMessagingWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api/v1", WhisprMessagingWeb do
    pipe_through :api

    # Health check endpoints
    get "/health", HealthController, :check
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
    get "/health/detailed", HealthController, :detailed

    # Conversation routes
    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    # Conversation members
    post "/conversations/:id/members", ConversationController, :add_member
    delete "/conversations/:id/members/:user_id", ConversationController, :remove_member

    get "/conversations/:id/messages", MessageController, :index
    post "/conversations/:id/messages", MessageController, :create
    get "/messages/:id", MessageController, :show
    put "/messages/:id", MessageController, :update
    delete "/messages/:id", MessageController, :delete

    # Attachment routes
    post "/attachments/upload", AttachmentController, :upload
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/download", AttachmentController, :download
    delete "/attachments/:id", AttachmentController, :delete
  end

  def swagger_info do
    %{
      info: %{
        version: "1.0",
        title: "Whispr Messaging Service API",
        description: "API documentation for the Whispr Messaging Service",
        contact: %{
          name: "Whispr Team",
          email: "support@whispr.com"
        }
      },
      host: "localhost:8080",
      basePath: "/api/v1",
      schemes: ["http"],
      consumes: ["application/json"],
      produces: ["application/json"],
      securityDefinitions: %{
        Bearer: %{
          type: "apiKey",
          name: "Authorization",
          in: "header",
          description: "JWT Authorization header using the Bearer scheme. Example: \"Authorization: Bearer {token}\""
        }
      }
    }
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
