defmodule WhisprMessagingWeb.HealthController do
  @moduledoc """
  Health check endpoints for monitoring and orchestration systems.

  Provides comprehensive health checks including:
  - General health status with all dependencies
  - Liveness probe for container orchestration
  - Readiness probe for load balancer integration
  """

  use WhisprMessagingWeb, :controller

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
    # Default health check with measurements
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
  defp get_conversation_metrics do
    try do
      # Try to ping Redis
      case Redix.command(:redix, ["PING"]) do
        {:ok, "PONG"} -> :ok
        _ -> {:error, :redis}
      end
    rescue
      _ -> {:error, :redis}
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
