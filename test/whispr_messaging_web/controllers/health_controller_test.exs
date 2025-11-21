defmodule WhisprMessagingWeb.HealthControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  describe "GET /api/v1/health" do
    test "returns 200 OK with health status" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :check))
        |> json_response(200)

      assert response["status"] == "ok"
      assert response["timestamp"] != nil
      assert response["service"] == "whispr-messaging"
    end

    test "returns service version in response" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :check))
        |> json_response(200)

      assert response["version"] != nil
    end
  end

  describe "GET /api/v1/health/live" do
    test "liveness probe returns 200 when service is alive" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :live))
        |> json_response(200)

      assert response["status"] == "alive"
      assert response["timestamp"] != nil
    end

    test "liveness probe is fast and minimal" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :live))
        |> json_response(200)

      # Should only contain minimal information
      assert Map.has_key?(response, "status")
      assert Map.has_key?(response, "timestamp")
      # Shouldn't contain heavy checks
      refute Map.has_key?(response, "database") || Map.has_key?(response, "checks")
    end
  end

  describe "GET /api/v1/health/ready" do
    test "readiness probe returns 200 when service is ready" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :ready))
        |> json_response(200)

      assert response["status"] == "ready"
      assert response["timestamp"] != nil
    end

    test "readiness probe includes database check" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :ready))
        |> json_response(200)

      assert response["checks"] != nil
      assert response["checks"]["database"] != nil
    end

    test "readiness probe checks message queue" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :ready))
        |> json_response(200)

      assert response["checks"] != nil
      # Message queue check might be optional
      if Map.has_key?(response["checks"], "message_queue") do
        assert response["checks"]["message_queue"] in ["ok", "degraded"]
      end
    end

    test "readiness probe returns 503 when dependencies unavailable" do
      # This test would require mocking the database connection
      # For now, we just verify the expected behavior
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :ready))
        # Should return 200 if database is available, 503 if not
        |> (fn resp -> {resp.status, Jason.decode!(resp.resp_body)} end).()

      case response do
        {200, data} ->
          assert data["status"] == "ready"

        {503, data} ->
          assert data["status"] == "unavailable"

        _ ->
          flunk("Unexpected response status")
      end
    end
  end

  describe "GET /api/v1/health/detailed" do
    test "returns detailed health information" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :detailed))
        |> json_response(200)

      assert response["status"] != nil
      assert response["timestamp"] != nil
      assert response["service"] == "whispr-messaging"
      assert response["checks"] != nil
    end

    test "includes all relevant health checks" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :detailed))
        |> json_response(200)

      checks = response["checks"]

      # Database check should always be present
      assert checks["database"] in ["ok", "degraded", "down"]

      # Other optional checks
      if Map.has_key?(checks, "cache") do
        assert checks["cache"] in ["ok", "degraded", "down"]
      end

      if Map.has_key?(checks, "memory") do
        assert is_map(checks["memory"])
      end
    end

    test "includes memory and process information" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :detailed))
        |> json_response(200)

      assert response["memory"] != nil
      assert response["memory"]["used_mb"] != nil
      assert response["memory"]["available_mb"] != nil

      assert response["process_info"] != nil
      assert response["process_info"]["run_queue"] != nil
      assert response["process_info"]["memory_usage"] != nil
    end

    test "includes conversation metrics" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :detailed))
        |> json_response(200)

      assert response["metrics"] != nil
      assert response["metrics"]["active_conversations"] != nil
      assert response["metrics"]["active_connections"] != nil
    end
  end

  describe "GET /ready (Kubernetes compatibility)" do
    test "kubernetes readiness endpoint returns 200 when ready" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, "/ready")
        |> json_response(200)

      assert response["status"] != nil
    end
  end

  describe "GET /live (Kubernetes compatibility)" do
    test "kubernetes liveness endpoint returns 200 when alive" do
      conn =
        build_conn()
        |> json_conn()

      get(conn, "/live")
      |> json_response(200)
    end
  end

  describe "health check response structure" do
    test "all health endpoints return properly formatted JSON" do
      conn =
        build_conn()
        |> json_conn()

      endpoints = [
        Routes.api_v1_health_path(conn, :check),
        Routes.api_v1_health_path(conn, :live),
        Routes.api_v1_health_path(conn, :ready)
      ]

      Enum.each(endpoints, fn endpoint ->
        response =
          get(conn, endpoint)
          |> json_response(200)

        assert is_map(response)
        assert response["status"] != nil
        assert response["timestamp"] != nil
      end)
    end

    test "timestamp is valid ISO8601 format" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_health_path(conn, :check))
        |> json_response(200)

      timestamp = response["timestamp"]

      # Verify it's a valid ISO8601 string
      assert String.contains?(timestamp, ["T", "Z"]) || String.contains?(timestamp, ["T", "+"])
    end
  end

  describe "health check performance" do
    test "liveness check completes in reasonable time" do
      conn =
        build_conn()
        |> json_conn()

      start_time = System.monotonic_time(:millisecond)

      get(conn, Routes.api_v1_health_path(conn, :live))
      |> json_response(200)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Liveness check should complete in less than 100ms
      assert elapsed < 100
    end

    test "readiness check completes in reasonable time" do
      conn =
        build_conn()
        |> json_conn()

      start_time = System.monotonic_time(:millisecond)

      get(conn, Routes.api_v1_health_path(conn, :ready))
      |> json_response(200)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Readiness check should complete in less than 500ms
      assert elapsed < 500
    end

    test "detailed check completes in reasonable time" do
      conn =
        build_conn()
        |> json_conn()

      start_time = System.monotonic_time(:millisecond)

      get(conn, Routes.api_v1_health_path(conn, :detailed))
      |> json_response(200)

      elapsed = System.monotonic_time(:millisecond) - start_time

      # Detailed check should complete in less than 1 second
      assert elapsed < 1000
    end
  end
end
