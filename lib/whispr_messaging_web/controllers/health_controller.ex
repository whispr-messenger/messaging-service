defmodule WhisprMessagingWeb.HealthController do
  @moduledoc """
  Health check endpoints for Kubernetes liveness and readiness probes.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Repo

  @doc """
  Basic health check endpoint.
  Returns 200 OK if service is running.
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
    # Default health check
    json(conn, %{
      status: "ok",
      service: "whispr-messaging",
      version: Application.spec(:whispr_messaging, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Private functions

  defp check_database do
    try do
      Repo.query!("SELECT 1")
      :ok
    rescue
      _ -> {:error, :database}
    end
  end

  defp check_redis do
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
end
