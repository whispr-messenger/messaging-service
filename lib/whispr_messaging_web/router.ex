defmodule WhisprMessagingWeb.Router do
  @moduledoc """
  Phoenix router for WhisprMessaging web interface.

  Defines HTTP routes for the messaging service API and health endpoints.
  """

  use WhisprMessagingWeb, :router
  use PhoenixSwagger

  pipeline :api do
    plug :accepts, ["json"]
    plug WhisprMessagingWeb.Plugs.Authenticate
  end

  scope "/api/swagger" do
    forward "/", PhoenixSwagger.Plug.SwaggerUI,
      otp_app: :whispr_messaging,
      swagger_file: "swagger.json"
  end

  # Swagger API info
  # https://hexdocs.pm/phoenix_swagger/getting-started.html#router
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
    get "/conversations/search", ConversationController, :search
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete
    post "/conversations/:id/delete_for_me", ConversationController, :delete_for_me
    delete "/conversations/:id/all", ConversationController, :delete_for_all
    post "/conversations/:id/leave", ConversationController, :leave
    post "/conversations/:id/pin", ConversationController, :pin
    delete "/conversations/:id/pin", ConversationController, :unpin

    # Conversation members
    post "/conversations/:id/members", ConversationMemberController, :create
    delete "/conversations/:id/members/:user_id", ConversationMemberController, :delete
    patch "/conversations/:id/members/:user_id/role", ConversationMemberController, :update_role

    # Per-user conversation settings (WHISPR-467)
    get "/conversations/:id/settings", ConversationController, :get_member_settings
    put "/conversations/:id/settings", ConversationController, :update_member_settings

    get "/conversations/:id/messages", MessageController, :index
    post "/conversations/:id/messages", MessageController, :create
    get "/conversations/:id/pins", PinController, :index
    get "/messages/:id", MessageController, :show
    put "/messages/:id", MessageController, :update
    delete "/messages/:id", MessageController, :delete
    get "/messages/:id/edit_history", MessageController, :edit_history
    get "/messages/:id/status", MessageController, :delivery_status
    post "/messages/:id/delivered", MessageController, :mark_delivered
    post "/messages/:id/read", MessageController, :mark_read
    post "/messages/:id/pin", PinController, :create
    delete "/messages/:id/pin", PinController, :delete

    # Attachment routes
    post "/attachments/upload", AttachmentController, :upload
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/download", AttachmentController, :download
    delete "/attachments/:id", AttachmentController, :delete
  end
end
