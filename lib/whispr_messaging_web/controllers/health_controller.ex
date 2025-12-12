defmodule WhisprMessagingWeb.HealthController do
  @moduledoc """
  Health check endpoints for monitoring and orchestration systems.

  Provides comprehensive health checks including:
  - General health status with all dependencies
  - Liveness probe for container orchestration
  - Readiness probe for load balancer integration
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger
  require Logger

  alias WhisprMessaging.Repo

  swagger_path :check do
    get("/health")
    summary("Comprehensive health check")
    description("Returns the health status of the service and all its dependencies")
    produces("application/json")
    response(200, "Success", Schema.ref(:HealthResponse))
    response(500, "Internal Server Error")
  end

  @doc """
  Comprehensive health check endpoint.

  Returns the health status of the service and all its dependencies
  including database, cache, memory usage, and uptime metrics.

  ## Response
  - 200 OK: Service and all dependencies are healthy
  - 500 Internal Server Error: One or more dependencies are unhealthy
  """
  def check(conn, _params) do
    Logger.debug("Health check started")

    start_time = System.monotonic_time(:millisecond)

    # Get system information
    uptime_seconds = get_uptime_seconds()
    memory = get_memory_info()
    version = get_version()

    # Check dependencies
    {database_status, database_time} = measure_check(&check_database/0)
    {cache_status, cache_time} = measure_check(&check_redis/0)

    total_time = System.monotonic_time(:millisecond) - start_time

    # Determine overall status
    overall_status =
      if database_status == "healthy" and cache_status == "healthy" do
        "ok"
      else
        "error"
      end

    health = %{
      status: overall_status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: "whispr-messaging",
      version: version,
      uptime: %{
        seconds: uptime_seconds,
        human: format_uptime(uptime_seconds)
      },
      memory: memory,
      services: %{
        database: %{
          status: database_status,
          response_time_ms: database_time
        },
        cache: %{
          status: cache_status,
          response_time_ms: cache_time
        }
      },
      check_duration_ms: total_time
    }

    Logger.debug("Health check completed: #{inspect(health)}")

    status_code = if overall_status == "ok", do: :ok, else: :internal_server_error

    conn
    |> put_status(status_code)
    |> json(health)
  end

  swagger_path :live do
    get("/health/live")
    summary("Liveness probe")
    description("Returns whether the service is alive and responding")
    produces("application/json")
    response(200, "Success", Schema.ref(:LivenessResponse))
  end

  @doc """
  Liveness probe endpoint.

  Returns whether the service is alive and responding.
  This should only fail if the application is completely unresponsive.

  ## Response
  Always returns 200 OK if the application can respond to requests.
  """
  def live(conn, _params) do
    Logger.debug("Liveness check requested")

    uptime_seconds = get_uptime_seconds()

    response = %{
      status: "alive",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: "whispr-messaging",
      version: get_version(),
      uptime: %{
        seconds: uptime_seconds,
        human: format_uptime(uptime_seconds)
      },
      memory: get_memory_info()
    }

    json(conn, response)
  end

  swagger_path :ready do
    get("/health/ready")
    summary("Readiness probe")
    description("Returns whether the service is ready to accept traffic")
    produces("application/json")
    response(200, "Service is ready", Schema.ref(:ReadinessResponse))
    response(503, "Service is not ready")
  end

  swagger_path :detailed do
    get("/health/detailed")
    summary("Detailed health information")
    description("Returns comprehensive health metrics including conversation and process information")
    produces("application/json")
    response(200, "Success", Schema.ref(:DetailedHealthResponse))
    response(500, "Internal Server Error")
  end

  @doc """
  Detailed health check endpoint.

  Returns comprehensive health metrics including:
  - All dependency health checks
  - Memory and process information
  - Conversation server metrics
  - System resource usage

  ## Response
  - 200 OK: Service is healthy with detailed metrics
  - 500 Internal Server Error: One or more dependencies are unhealthy
  """
  def detailed(conn, _params) do
    Logger.debug("Detailed health check started")

    start_time = System.monotonic_time(:millisecond)

    # Get system information
    uptime_seconds = get_uptime_seconds()
    memory = get_memory_info()
    version = get_version()

    # Check dependencies
    {database_status, database_time} = measure_check(&check_database/0)
    {cache_status, cache_time} = measure_check(&check_redis/0)

    # Get process information
    process_info = get_process_info()

    # Get conversation metrics
    conversation_metrics = get_conversation_metrics()

    total_time = System.monotonic_time(:millisecond) - start_time

    # Determine overall status
    overall_status =
      if database_status == "healthy" and cache_status == "healthy" do
        "ok"
      else
        "error"
      end

    memory_info = %{
      used_mb: Map.get(memory, :used, 0) / 1_048_576,
      available_mb: (Map.get(memory, :total, 0) - Map.get(memory, :used, 0)) / 1_048_576
    }

    health = %{
      status: overall_status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: "whispr-messaging",
      version: version,
      uptime: %{
        seconds: uptime_seconds,
        human: format_uptime(uptime_seconds)
      },
      memory: memory_info,
      checks: %{
        database: if(database_status == "healthy", do: "ok", else: "down"),
        cache: if(cache_status == "healthy", do: "ok", else: "down")
      },
      metrics: conversation_metrics,
      process_info: process_info,
      services: %{
        database: %{
          status: database_status,
          response_time_ms: database_time
        },
        cache: %{
          status: cache_status,
          response_time_ms: cache_time
        }
      },
      conversations: conversation_metrics,
      check_duration_ms: total_time
    }

    Logger.debug("Detailed health check completed: #{inspect(health)}")

    status_code = if overall_status == "ok", do: :ok, else: :internal_server_error

    conn
    |> put_status(status_code)
    |> json(health)
  end

  @doc """
  Readiness probe endpoint.

  Returns whether the service is ready to accept traffic.
  Checks that all critical dependencies (database and cache) are accessible.

  ## Response
  - 200 OK: Service is ready to accept traffic
  - 503 Service Unavailable: Service is not ready (dependencies unavailable)
  """
  def ready(conn, _params) do
    Logger.debug("Readiness check started")

    {database_status, database_time} = measure_check(&check_database/0)
    {cache_status, cache_time} = measure_check(&check_redis/0)

    ready = database_status == "healthy" and cache_status == "healthy"

    response = %{
      status: if(ready, do: "ready", else: "not_ready"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: "whispr-messaging",
      checks: %{
        database: %{
          status: database_status,
          response_time_ms: database_time
        },
        cache: %{
          status: cache_status,
          response_time_ms: cache_time
        }
      }
    }

    status_code = if ready, do: :ok, else: :service_unavailable

    Logger.debug("Readiness check completed: #{if ready, do: "ready", else: "not ready"}")

    conn
    |> put_status(status_code)
    |> json(response)
  end

  # Private functions

  @doc false
  defp check_database do
    Logger.debug("Checking database connection")
    Repo.query!("SELECT 1")
    Logger.debug("Database check passed")
    :ok
  rescue
    error ->
      Logger.error("Database check failed: #{inspect(error)}")
      {:error, :database}
  end

  @doc false
  defp check_redis do
    Logger.debug("Checking cache connection")

    # Try to set and get a health check value
    set_result = Redix.command(:redix, ["SET", "health-check", "ok", "EX", "1"])
    Logger.debug("Redis SET result: #{inspect(set_result)}")

    case set_result do
      {:ok, _} ->
        get_result = Redix.command(:redix, ["GET", "health-check"])
        Logger.debug("Redis GET result: #{inspect(get_result)}")

        case get_result do
          {:ok, _} ->
            Logger.debug("Cache check passed")
            :ok

          error ->
            Logger.error("Cache check failed: unable to read test value - #{inspect(error)}")
            {:error, :redis}
        end

      error ->
        Logger.error("Cache check failed: unable to set test value - #{inspect(error)}")
        {:error, :redis}
    end
  rescue
    error ->
      Logger.error("Cache check failed with exception: #{inspect(error)}")
      {:error, :redis}
  end

  @doc false
  defp measure_check(check_fn) do
    start_time = System.monotonic_time(:millisecond)

    status =
      case check_fn.() do
        :ok -> "healthy"
        {:error, _} -> "unhealthy"
      end

    elapsed_time = System.monotonic_time(:millisecond) - start_time

    {status, elapsed_time}
  end

  @doc false
  defp get_memory_info do
    memory = :erlang.memory()

    %{
      total_bytes: memory[:total],
      total_mb: Float.round(memory[:total] / 1_048_576, 2),
      processes_bytes: memory[:processes],
      processes_mb: Float.round(memory[:processes] / 1_048_576, 2),
      system_bytes: memory[:system],
      system_mb: Float.round(memory[:system] / 1_048_576, 2),
      atom_bytes: memory[:atom],
      atom_mb: Float.round(memory[:atom] / 1_048_576, 2),
      binary_bytes: memory[:binary],
      binary_mb: Float.round(memory[:binary] / 1_048_576, 2),
      ets_bytes: memory[:ets],
      ets_mb: Float.round(memory[:ets] / 1_048_576, 2)
    }
  end

  @doc false
  defp get_process_info do
    memory = :erlang.memory()

    %{
      count: :erlang.system_info(:process_count),
      limit: :erlang.system_info(:process_limit),
      usage_percent: Float.round(:erlang.system_info(:process_count) / :erlang.system_info(:process_limit) * 100, 2),
      run_queue: :erlang.statistics(:run_queue),
      memory_usage: %{
        total_mb: Float.round(memory[:total] / 1_048_576, 2),
        processes_mb: Float.round(memory[:processes] / 1_048_576, 2),
        atom_mb: Float.round(memory[:atom] / 1_048_576, 2),
        binary_mb: Float.round(memory[:binary] / 1_048_576, 2),
        ets_mb: Float.round(memory[:ets] / 1_048_576, 2)
      }
    }
  end

  @doc false
  defp get_conversation_metrics do
    try do
      # Get conversation supervisor metrics if available
      supervisor_pid = Process.whereis(WhisprMessaging.ConversationSupervisor)

      if supervisor_pid do
        children = Supervisor.which_children(WhisprMessaging.ConversationSupervisor)
        active_conversations = Enum.count(children, fn {_, pid, _, _} -> is_pid(pid) end)

        %{
          active_conversations: active_conversations,
          active_connections: active_conversations,
          supervisor_alive: true
        }
      else
        %{
          active_conversations: 0,
          active_connections: 0,
          supervisor_alive: false
        }
      end
    rescue
      _ ->
        %{
          active_conversations: 0,
          active_connections: 0,
          supervisor_alive: false,
          error: "Unable to fetch conversation metrics"
        }
    end
  end

  @doc false
  defp get_version do
    Application.spec(:whispr_messaging, :vsn)
    |> to_string()
  end

  @doc false
  defp get_uptime_seconds do
    start_time = :persistent_term.get(:app_start_time, System.monotonic_time(:second))
    System.monotonic_time(:second) - start_time
  end

  @doc false
  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m #{secs}s"
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      HealthResponse:
        swagger_schema do
          title("Health Response")
          description("Comprehensive health check response")

          properties do
            status(:string, "Overall status", example: "ok")
            timestamp(:string, "ISO8601 timestamp", example: "2025-12-11T21:53:00Z")
            service(:string, "Service name", example: "whispr-messaging")
            version(:string, "Service version", example: "1.0.0")
            uptime(:object, "Uptime information")
            memory(:object, "Memory usage information")
            services(:object, "Status of dependent services")
            check_duration_ms(:integer, "Health check duration in milliseconds")
          end
        end,
      LivenessResponse:
        swagger_schema do
          title("Liveness Response")
          description("Liveness probe response")

          properties do
            status(:string, "Liveness status", example: "alive")
            timestamp(:string, "ISO8601 timestamp")
            service(:string, "Service name", example: "whispr-messaging")
            version(:string, "Service version")
            uptime(:object, "Uptime information")
            memory(:object, "Memory usage information")
          end
        end,
      ReadinessResponse:
        swagger_schema do
          title("Readiness Response")
          description("Readiness probe response")

          properties do
            status(:string, "Readiness status", example: "ready")
            timestamp(:string, "ISO8601 timestamp")
            service(:string, "Service name", example: "whispr-messaging")
            checks(:object, "Status of critical dependencies")
          end
        end,
      DetailedHealthResponse:
        swagger_schema do
          title("Detailed Health Response")
          description("Comprehensive health check with detailed metrics")

          properties do
            status(:string, "Overall status", example: "ok")
            timestamp(:string, "ISO8601 timestamp")
            service(:string, "Service name", example: "whispr-messaging")
            version(:string, "Service version")
            uptime(:object, "Uptime information")
            memory(:object, "Memory usage information")
            processes(:object, "Process count and limits")
            services(:object, "Status of dependent services")
            conversations(:object, "Conversation server metrics")
            check_duration_ms(:integer, "Health check duration in milliseconds")
          end
        end
    }
  end
end
