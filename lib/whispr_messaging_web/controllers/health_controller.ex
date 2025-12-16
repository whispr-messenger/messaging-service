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
    get "/health"
    summary "Comprehensive health check"
    description "Returns the health status of the service and all its dependencies"
    produces "application/json"
    response 200, "Success", Schema.ref(:HealthResponse)
    response 500, "Internal Server Error"
  end

  @doc """
  Service information endpoint for root path.

  Returns basic service information.
  """
  def info(conn, _params) do
    json(conn, %{
      service: "Whispr Messaging Service",
      version: "1.0.0",
      status: "running",
      endpoints: %{
        health: "/api/v1/health",
        swagger: "/api/swagger",
        websocket: "ws://#{conn.host}:#{conn.port}/socket"
      }
    })
  end

  @doc """
  Comprehensive health check endpoint.

  Returns the health status of the service and all its dependencies
  including database, cache, memory usage, and uptime metrics.

  ## Response
  - 200 OK: Service and all dependencies are healthy
  - 500 Internal Server Error: One or more dependencies are unhealthy
  """
  def check(conn, %{"type" => "live"}) do
    # Liveness probe - just check if the app is running
    json(conn, %{
      status: "ok",
      service: "whispr-messaging",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: "liveness"
    })
  end

  def check(conn, %{"type" => "ready"}) do
    # Readiness probe - check if dependencies are available
    with :ok <- check_database(),
         :ok <- check_redis() do
      json(conn, %{
        status: "ready",
        service: "whispr-messaging",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        type: "readiness",
        checks: %{
          database: "ok",
          redis: "ok"
        }
      })
    else
      {:error, :database} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "not_ready",
          service: "whispr-messaging",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          checks: %{
            database: "failed",
            redis: "unknown"
          }
        })

      {:error, :redis} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "not_ready",
          service: "whispr-messaging",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          checks: %{
            database: "ok",
            redis: "failed"
          }
        })
    end
  end

  def check(conn, _params) do
    # Default health check - comprehensive check of all dependencies
    with :ok <- check_database(),
         :ok <- check_redis() do
      uptime_seconds = get_uptime_seconds()
      
      json(conn, %{
        status: "healthy",
        service: "whispr-messaging",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        version: get_version(),
        uptime: %{
          seconds: uptime_seconds,
          human: format_uptime(uptime_seconds)
        },
        checks: %{
          database: "ok",
          redis: "ok"
        },
        memory: get_memory_info()
      })
    else
      {:error, :database} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "unhealthy",
          service: "whispr-messaging",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          checks: %{
            database: "failed",
            redis: "unknown"
          }
        })

      {:error, :redis} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "unhealthy",
          service: "whispr-messaging",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          checks: %{
            database: "ok",
            redis: "failed"
          }
        })
    end
  end

  swagger_path :live do
    get "/health/live"
    summary "Liveness probe"
    description "Returns whether the service is alive and responding"
    produces "application/json"
    response 200, "Success", Schema.ref(:LivenessResponse)
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
    get "/health/ready"
    summary "Readiness probe"
    description "Returns whether the service is ready to accept traffic"
    produces "application/json"
    response 200, "Service is ready", Schema.ref(:ReadinessResponse)
    response 503, "Service is not ready"
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

    all_healthy = database_status == "healthy" && cache_status == "healthy"
    status_code = if all_healthy, do: :ok, else: :service_unavailable

    response = %{
      status: if(all_healthy, do: "ok", else: "degraded"),
      service: "whispr-messaging",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
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

    conn
    |> put_status(status_code)
    |> json(response)
  end

  # Private functions

  @doc false
  defp check_database do
    try do
      Repo.query!("SELECT 1")
      :ok
    rescue
      _ -> {:error, :database}
    end
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
  defp get_uptime_seconds do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    div(uptime_ms, 1000)
  end

  @doc false
  defp get_version do
    Application.spec(:whispr_messaging, :vsn)
    |> to_string()
  end

  @doc false
  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)
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
      HealthResponse: swagger_schema do
        title "Health Response"
        description "Health check response from GET /health endpoint. When healthy, includes version, uptime, checks, and memory. When unhealthy, only includes status, service, timestamp, and checks."
        properties do
          status :string, "Overall status (healthy or unhealthy)", example: "healthy"
          timestamp :string, "ISO8601 timestamp", example: "2025-12-11T21:53:00Z"
          service :string, "Service name", example: "whispr-messaging"
          version :string, "Service version (only when healthy)", example: "1.0.0"
          uptime(:object, "Uptime information (only when healthy)", required: false) do
            property :seconds, :integer, "Uptime in seconds"
            property :human, :string, "Human-readable uptime", example: "1d 2h 30m 15s"
          end
          checks(:object, "Status of dependencies") do
            property :database, :string, "Database status (ok, failed, or unknown)"
            property :redis, :string, "Redis status (ok, failed, or unknown)"
          end
          memory(:object, "Memory usage information (only when healthy)", required: false) do
            property :total_bytes, :integer, "Total memory in bytes"
            property :total_mb, :number, "Total memory in MB"
            property :processes_bytes, :integer, "Process memory in bytes"
            property :used_mb, :number, "Used memory in MB"
          end
        end
      end,
      LivenessResponse: swagger_schema do
        title "Liveness Response"
        description "Liveness probe response"
        properties do
          status :string, "Liveness status", example: "alive"
          timestamp :string, "ISO8601 timestamp"
          service :string, "Service name", example: "whispr-messaging"
          version :string, "Service version"
          uptime :object, "Uptime information"
          memory :object, "Memory usage information"
        end
      end,
      ReadinessResponse: swagger_schema do
        title "Readiness Response"
        description "Readiness probe response"
        properties do
          status :string, "Readiness status", example: "ready"
          timestamp :string, "ISO8601 timestamp"
          service :string, "Service name", example: "whispr-messaging"
          checks :object, "Status of critical dependencies"
        end
      end
    }
  end
end
