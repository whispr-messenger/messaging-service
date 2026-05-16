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
    WhisprMessaging.TelemetryHandlers.attach()
    Logger.info("Application starting")

    # Store application start time
    :persistent_term.put(:app_start_time, System.monotonic_time(:second))

    # Order matters: JwksCache must be started BEFORE the Endpoint so
    # incoming HTTP/WebSocket traffic never finds a :noproc when verifying
    # JWTs. Same for Redis (env_specific) which the Endpoint plugs rely on.
    children =
      pre_endpoint_children() ++
        env_specific_children() ++
        optional_children() ++
        endpoint_children()

    opts = [strategy: :one_for_one, name: WhisprMessaging.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Application started")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Application start failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Infrastructure and dependencies that must be running BEFORE the Endpoint
  # accepts traffic.
  defp pre_endpoint_children do
    [
      # Database
      WhisprMessaging.Repo,

      # HTTP client pool (used by JwksCache to fetch JWKS)
      {Finch, name: WhisprMessaging.Finch},

      # PubSub for Phoenix Channels
      {Phoenix.PubSub, name: WhisprMessaging.PubSub},

      # Telemetry supervision tree
      WhisprMessagingWeb.Telemetry,

      # Conversation registry and supervisor
      {Registry, keys: :unique, name: WhisprMessaging.ConversationRegistry},
      WhisprMessaging.ConversationSupervisor,
      {Task.Supervisor, name: WhisprMessaging.TaskSupervisor},

      # Presence tracking
      WhisprMessagingWeb.Presence
    ]
  end

  # The HTTP/WebSocket endpoint is started LAST so all the processes it
  # depends on (Repo, PubSub, JwksCache, Redis) are already up.
  defp endpoint_children do
    [WhisprMessagingWeb.Endpoint]
  end

  defp env_specific_children do
    [
      # Redis connections (enabled for all environments)
      {Redix, [name: :redix] ++ WhisprMessaging.RedisConfig.build()}
      # gRPC server disabled for now - needs config update
      # {GRPC.Server.Supervisor, grpc_server_config()}
    ]
  end

  # Children that are started in dev/prod but NOT in :test, because tests
  # manage their lifecycle explicitly (start_supervised!/start_link) for
  # determinism and to avoid the supervisor restart cascade tripping over
  # tests that stop these processes. Gated by the `:start_background_workers`
  # application env flag (default true) — `Mix.env()` is not safe to call from
  # an OTP release at runtime.
  defp optional_children do
    if Application.get_env(:whispr_messaging, :start_background_workers, true) do
      [
        WhisprMessaging.JwksCache,
        WhisprMessaging.Workers.EphemeralMessageCleaner,
        WhisprMessaging.Workers.ScheduledMessageWorker,
        WhisprMessaging.Workers.SanctionExpiryWorker,
        WhisprMessaging.Workers.ModerationSubscriber,
        WhisprMessaging.Workers.CallsSubscriber
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisprMessagingWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # defp grpc_server_config do
  #   port = Application.get_env(:whispr_messaging, :grpc_port, 50_052)
  #   {WhisprMessaging.GRPC.Server, port}
  # end
end
