defmodule WhisprMessaging.Application do
  @moduledoc """
  The WhisprMessaging Application callback module.

  This module defines the OTP application structure with supervision tree
  for fault-tolerant real-time messaging functionality.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting WhisprMessaging application...")

    children = [
      # Database
      WhisprMessaging.Repo,

      # Redis connections
      {Redix, redis_config()},
      %{
        id: Redix.PubSub,
        start: {Redix.PubSub, :start_link, [[name: :redix_pubsub] ++ redis_config()]}
      },

      # PubSub for Phoenix Channels
      {Phoenix.PubSub, name: WhisprMessaging.PubSub},

      # Conversation registry and supervisor
      {Registry, keys: :unique, name: WhisprMessaging.ConversationRegistry},

      WhisprMessaging.ConversationSupervisor,

      # Presence tracking
      WhisprMessagingWeb.Presence,

      # Phoenix Endpoint
      WhisprMessagingWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WhisprMessaging.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("WhisprMessaging application started successfully")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start WhisprMessaging application: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisprMessagingWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp redis_config do
    Application.get_env(:whispr_messaging, :redis,
      host: "localhost",
      port: 6379,
      database: 0
    )
  end
end
