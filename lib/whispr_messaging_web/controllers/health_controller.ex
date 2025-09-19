defmodule WhisprMessagingWeb.HealthController do
  use WhisprMessagingWeb, :controller

  # Pas d'authentification requise pour le health check
  
  @doc """
  Endpoint racine du service
  """
  def index(conn, _params) do
    json(conn, %{
      service: "messaging-service",
      status: "running",
      version: Application.spec(:whispr_messaging, :vsn) |> to_string(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      endpoints: %{
        health: "/api/health",
        conversations: "/api/v1/conversations",
        messages: "/api/v1/messages"
      }
    })
  end

  @doc """
  Health check endpoint pour vérifier l'état du service
  """
  def check(conn, _params) do
    # Vérifier la connectivité à la base de données
    db_status = check_database()
    
    # Vérifier la connectivité Redis (optionnel)
    redis_status = check_redis()
    
    # Statut global
    overall_status = if db_status == :ok and redis_status in [:ok, :unavailable] do
      :healthy
    else
      :unhealthy
    end
    
    status_code = case overall_status do
      :healthy -> 200
      :unhealthy -> 503
    end
    
    response = %{
      status: overall_status,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: "messaging-service",
      version: Application.spec(:whispr_messaging, :vsn) |> to_string(),
      checks: %{
        database: db_status,
        redis: redis_status
      },
      uptime: get_uptime()
    }
    
    conn
    |> put_status(status_code)
    |> json(response)
  end
  
  # Vérification de la base de données
  defp check_database do
    try do
      # Test simple de connectivité à la base de données
      WhisprMessaging.Repo.query("SELECT 1", [])
      :ok
    rescue
      _ -> :error
    end
  end
  
  # Vérification de Redis (optionnel)
  defp check_redis do
    try do
      # Test de connectivité Redis si configuré
      case Application.get_env(:whispr_messaging, :redis_url) do
        nil -> :unavailable
        _url ->
          # Ici on pourrait tester la connectivité Redis
          # Pour l'instant on retourne :ok
          :ok
      end
    rescue
      _ -> :error
    end
  end
  
  # Calcul de l'uptime
  defp get_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_seconds = div(uptime_ms, 1000)
    
    hours = div(uptime_seconds, 3600)
    minutes = div(rem(uptime_seconds, 3600), 60)
    seconds = rem(uptime_seconds, 60)
    
    "#{hours}h #{minutes}m #{seconds}s"
  end
end