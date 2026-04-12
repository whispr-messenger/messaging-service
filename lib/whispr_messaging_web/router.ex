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

  scope "/messaging/api/swagger" do
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

  # Kubernetes-compatible health check routes (no prefix)
  scope "/", WhisprMessagingWeb do
    pipe_through :api

    get "/ready", HealthController, :ready
    get "/live", HealthController, :live
  end

  scope "/messaging/api/v1", WhisprMessagingWeb do
    pipe_through :api

    # Health check endpoints
    get "/health", HealthController, :check
    get "/health/detailed", HealthController, :detailed
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready

    # Conversation routes
    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create

    # Literal paths must come before parameterized :id routes
    get "/conversations/archived", ConversationController, :archived
    # Search must be declared before /:id to avoid Phoenix treating "search" as an ID
    get "/conversations/search", ConversationController, :search

    get "/conversations/:id", ConversationController, :show
    put "/conversations/:id", ConversationController, :update
    delete "/conversations/:id", ConversationController, :delete

    # Conversation members
    post "/conversations/:id/members", ConversationMemberController, :create
    delete "/conversations/:id/members/:user_id", ConversationMemberController, :delete

    # Per-user conversation settings (WHISPR-467)
    get "/conversations/:id/settings", ConversationController, :get_member_settings
    put "/conversations/:id/settings", ConversationController, :update_member_settings

    # Conversation pin / unpin (WHISPR-465)
    post "/conversations/:id/pin", ConversationController, :pin
    delete "/conversations/:id/pin", ConversationController, :unpin

    # Conversation archive / unarchive (WHISPR-466)
    post "/conversations/:id/archive", ConversationController, :archive
    delete "/conversations/:id/archive", ConversationController, :unarchive

    get "/conversations/:id/messages", MessageController, :index
    post "/conversations/:id/messages", MessageController, :create

    # Draft routes — literal paths must come before /messages/:id
    post "/messages/drafts", DraftController, :create
    delete "/messages/drafts/:id", DraftController, :delete

    # Draft retrieval scoped to conversation
    get "/conversations/:id/drafts", DraftController, :show

    # Scheduled message routes — literal paths before parameterized :id
    get "/messages/scheduled", ScheduledMessageController, :index
    post "/messages/scheduled", ScheduledMessageController, :create
    delete "/messages/scheduled/:id", ScheduledMessageController, :delete

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
