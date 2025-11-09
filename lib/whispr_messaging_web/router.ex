defmodule WhisprMessagingWeb.Router do
  @moduledoc """
  Phoenix router for WhisprMessaging API.

  Defines HTTP routes for the messaging service API and WebSocket endpoints.
  """

  use WhisprMessagingWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api/v1", WhisprMessagingWeb do
    pipe_through(:api)

    get("/health", HealthController, :check)
    get("/conversations", ConversationController, :index)
    post("/conversations", ConversationController, :create)
    get("/conversations/:id", ConversationController, :show)
    put("/conversations/:id", ConversationController, :update)
    delete("/conversations/:id", ConversationController, :delete)

    get("/conversations/:id/messages", MessageController, :index)
    post("/conversations/:id/messages", MessageController, :create)
    get("/messages/:id", MessageController, :show)
    put("/messages/:id", MessageController, :update)
    delete("/messages/:id", MessageController, :delete)
  end
end
