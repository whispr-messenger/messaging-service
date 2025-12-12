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

    # Store application start time
    :persistent_term.put(:app_start_time, System.monotonic_time(:second))

    children = base_children() ++ env_specific_children()

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

  defp base_children do
    [
      # Database
      WhisprMessaging.Repo,

      # PubSub for Phoenix Channels
      {Phoenix.PubSub, name: WhisprMessaging.PubSub},

      # Telemetry supervision tree
      WhisprMessagingWeb.Telemetry,

      # Conversation registry and supervisor
      {Registry, keys: :unique, name: WhisprMessaging.ConversationRegistry},
      WhisprMessaging.ConversationSupervisor,

      # Presence tracking
      WhisprMessagingWeb.Presence,

      # Phoenix Endpoint
      WhisprMessagingWeb.Endpoint
    ]
  end

  defp env_specific_children do
    if Mix.env() == :test do
      # Skip Redis and gRPC in test environment
      []
    else
      [
        # Redis connections
        {Redix, [name: :redix] ++ redis_config()}
        # gRPC server disabled for now - needs config update
        # {GRPC.Server.Supervisor, grpc_server_config()}
      ]
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

  defp grpc_server_config do
    port = Application.get_env(:whispr_messaging, :grpc_port, 50_052)
    {WhisprMessaging.GRPC.Server, port}
  end
end
