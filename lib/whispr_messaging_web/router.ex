defmodule WhisprMessagingWeb.Router do
  @moduledoc """
  Phoenix router for WhisprMessaging web interface.

  Defines HTTP routes for the messaging service API and health endpoints.
  """

  use WhisprMessagingWeb, :router
  use PhoenixSwagger

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/swagger" do
    forward "/", PhoenixSwagger.Plug.SwaggerUI,
      otp_app: :whispr_messaging,
      swagger_file: "swagger.json"
  end

  # Swagger API info
  def swagger_info do
    WhisprMessagingWeb.SwaggerInfo.swagger_info()
  end

  scope "/", WhisprMessagingWeb do
    pipe_through :api

    get "/", HealthController, :info
  end

  # Kubernetes-compatible health check routes (no /api/v1 prefix)
  scope "/", WhisprMessagingWeb do
    pipe_through :api

    get "/ready", HealthController, :ready
    get "/live", HealthController, :live
  end

  scope "/api/v1", WhisprMessagingWeb do
    pipe_through :api

    # Health check endpoints
    get "/health", HealthController, :check
    get "/health/detailed", HealthController, :detailed
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready

    # Conversation routes
    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    # Conversation members
    post "/conversations/:id/members", ConversationMemberController, :create
    delete "/conversations/:id/members/:user_id", ConversationMemberController, :delete

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
end
