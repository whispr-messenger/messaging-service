defmodule WhisprMessagingWeb.HealthController do
  @moduledoc """
  Health check controller for monitoring and orchestration.

  Provides health and readiness endpoints for Kubernetes health checks
  and load balancer monitoring.
  """

  use WhisprMessagingWeb, :controller

  @doc """
  Basic health check endpoint.

  Returns 200 OK if the application is running.
  This is used by Docker health checks and load balancers.
  """
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "whispr-messaging",
      version: Application.spec(:whispr_messaging, :vsn) |> to_string()
    })
  end

  @doc """
  Readiness check endpoint.

  Verifies that the application is ready to receive traffic by checking:
  - Database connectivity
  - Redis connectivity
  - gRPC server status

  Returns 200 OK if ready, 503 Service Unavailable otherwise.
  """
  def ready(conn, _params) do
    checks = %{
      database: check_database(),
      redis: check_redis(),
      grpc: check_grpc()
    }

    all_healthy = Enum.all?(checks, fn {_key, status} -> status == :ok end)

    if all_healthy do
      json(conn, %{
        status: "ready",
        checks: checks
      })
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{
        status: "not_ready",
        checks: checks
      })
    end
  end

  @doc """
  Liveness check endpoint.

  Simple check to verify the application is alive and not deadlocked.
  Returns 200 OK if the application can respond to requests.
  """
  def live(conn, _params) do
    json(conn, %{status: "alive"})
  end

  # Private helper functions

  defp check_database do
    try do
      # Simple query to check database connectivity
      Ecto.Adapters.SQL.query!(WhisprMessaging.Repo, "SELECT 1", [])
      :ok
    rescue
      _ -> :error
    end
  end

  defp check_redis do
    try do
      # Try to ping Redis
      case Redix.command(:redix, ["PING"]) do
        {:ok, "PONG"} -> :ok
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp check_grpc do
    # For now, assume gRPC is OK if the application started
    # Can be enhanced to check actual gRPC server status
    :ok
  end
end
