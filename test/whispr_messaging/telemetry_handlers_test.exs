defmodule WhisprMessaging.TelemetryHandlersTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.TelemetryHandlers

  describe "handle_ecto_query/4" do
    test "logs a warning when total_time >= threshold" do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          TelemetryHandlers.handle_ecto_query(
            [:whispr_messaging, :repo, :query],
            %{
              total_time: System.convert_time_unit(1_000, :millisecond, :native),
              queue_time: System.convert_time_unit(10, :millisecond, :native),
              query_time: System.convert_time_unit(900, :millisecond, :native),
              decode_time: System.convert_time_unit(5, :millisecond, :native)
            },
            %{query: "SELECT 1", source: "test"},
            %{threshold_ms: 500}
          )
        end)

      assert log =~ "Slow query detected"
    end

    test "is silent when below the threshold" do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          TelemetryHandlers.handle_ecto_query(
            [:whispr_messaging, :repo, :query],
            %{
              total_time: System.convert_time_unit(10, :millisecond, :native),
              queue_time: System.convert_time_unit(1, :millisecond, :native),
              query_time: System.convert_time_unit(9, :millisecond, :native),
              decode_time: nil
            },
            %{query: "SELECT 1", source: "test"},
            %{threshold_ms: 500}
          )
        end)

      refute log =~ "Slow query detected"
    end
  end

  describe "handle_phoenix_request/4" do
    test "runs without raising and logs (if level allows)" do
      # In :test the Logger level is :warning so :info is filtered; we just
      # assert the handler doesn't crash with the expected metadata shape.
      assert :ok =
               (
                 TelemetryHandlers.handle_phoenix_request(
                   [:phoenix, :endpoint, :stop],
                   %{duration: System.convert_time_unit(42, :millisecond, :native)},
                   %{
                     conn: %{
                       status: 200,
                       method: "GET",
                       request_path: "/api/v1/test"
                     }
                   },
                   nil
                 )

                 :ok
               )
    end
  end

  describe "attach/0" do
    test "registers the two named handlers without raising" do
      # Detach if any previous run left them
      :telemetry.detach("whispr-ecto-slow-query")
      :telemetry.detach("whispr-phoenix-request")

      assert :ok = TelemetryHandlers.attach()

      handlers =
        :telemetry.list_handlers([])
        |> Enum.map(& &1.id)

      assert "whispr-ecto-slow-query" in handlers
      assert "whispr-phoenix-request" in handlers
    end
  end
end
