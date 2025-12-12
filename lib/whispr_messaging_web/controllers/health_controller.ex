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
    try do
      Logger.debug("Checking database connection")
      Repo.query!("SELECT 1")
      Logger.debug("Database check passed")
      :ok
    rescue
      error ->
        Logger.error("Database check failed: #{inspect(error)}")
        {:error, :database}
    end
  end

  @doc false
  defp check_redis do
    try do
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
    days = div(seconds, 86400)
    hours = div(rem(seconds, 86400), 3600)
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
        end
    }
  end
end
