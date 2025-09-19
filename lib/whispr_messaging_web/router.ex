defmodule WhisprMessagingWeb.Router do
  use WhisprMessagingWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Endpoint racine simple
  scope "/", WhisprMessagingWeb do
    pipe_through :api
    
    get "/", HealthController, :index
  end

  scope "/api", WhisprMessagingWeb do
    pipe_through :api
    
    # Health check endpoint
    get "/health", HealthController, :check
  end

  scope "/api/v1", WhisprMessagingWeb do
    pipe_through :api

    # Conversations routes
    resources "/conversations", ConversationController, except: [:edit, :new] do
      # Routes imbriquées pour les messages d'une conversation
      resources "/messages", MessageController, only: [:index, :create]
      
      # Routes pour les messages épinglés
      get "/pinned-messages", MessageController, :pinned
      
      # Actions spécifiques aux conversations selon 1_chats_management.md
      
      # Gestion des membres (section 3.3)
      post "/members/:user_id", ConversationController, :add_member
      delete "/members/:user_id", ConversationController, :remove_member
      
      # Organisation des conversations (section 4)
      post "/pin", ConversationController, :pin
      delete "/pin", ConversationController, :unpin
      post "/archive", ConversationController, :archive
      delete "/archive", ConversationController, :unarchive
      
      # Configuration des paramètres (section 5)
      put "/settings", ConversationController, :configure_settings
      
      # Actions de lecture
      post "/mark-as-read", ConversationController, :mark_as_read
    end

    # Messages routes (actions sur des messages spécifiques)
    resources "/messages", MessageController, only: [:show, :update, :delete] do
      # Actions spécifiques aux messages
      post "/mark-as-read", MessageController, :mark_as_read
      post "/reactions", MessageController, :add_reaction
      delete "/reactions/:reaction", MessageController, :remove_reaction
      post "/pin", MessageController, :pin
      delete "/pin", MessageController, :unpin
    end

    # Routes pour les groupes selon la documentation
    resources "/groups", GroupController, except: [:edit, :new] do
      # Actions spécifiques aux groupes
      post "/members", GroupController, :add_members
      delete "/members", GroupController, :remove_members
      post "/leave", GroupController, :leave
    end

    # Routes pour les statuts de livraison et lecture selon la documentation
    scope "/status" do
      get "/messages/:message_id", StatusController, :show
      post "/messages/:message_id/read", StatusController, :mark_as_read
      post "/messages/read", StatusController, :mark_multiple_as_read
      post "/messages/:message_id/delivered", StatusController, :mark_as_delivered
      get "/conversations/:conversation_id/stats", StatusController, :conversation_stats
      get "/conversations/:conversation_id/unread", StatusController, :unread_messages
      get "/user/stats", StatusController, :user_stats
      put "/user/preferences", StatusController, :update_preferences
    end

    # Routes pour les statistiques et informations globales
    get "/conversations/stats/unread", ConversationController, :unread_stats
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:whispr_messaging, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: WhisprMessagingWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
