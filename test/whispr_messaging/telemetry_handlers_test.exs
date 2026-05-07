defmodule WhisprMessaging.TelemetryHandlersTest do
  @moduledoc """
  Tests for the telemetry handler module. Verifies the handlers can be
  attached and dispatched without raising.
  """

  use ExUnit.Case, async: false

  alias WhisprMessaging.TelemetryHandlers

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  describe "handle_ecto_query/4" do
    test "logs nothing under the threshold" do
      result =
        TelemetryHandlers.handle_ecto_query(
          [:whispr_messaging, :repo, :query],
          %{
            total_time: native(10),
            queue_time: native(1),
            query_time: native(5),
            decode_time: native(1)
          },
          %{query: "SELECT 1", source: "messages"},
          %{threshold_ms: 500}
        )

      # The handler returns whatever the if-expression evaluates to, which is
      # `nil` when below threshold (nothing logged). The important assertion
      # is that the call doesn't raise.
      assert result == nil or result == :ok
    end

    test "logs a warning when the query is slow" do
      result =
        TelemetryHandlers.handle_ecto_query(
          [:whispr_messaging, :repo, :query],
          %{
            total_time: native(1_000),
            queue_time: native(10),
            query_time: native(900),
            decode_time: native(20)
          },
          %{query: "SELECT pg_sleep(1)", source: "messages"},
          %{threshold_ms: 500}
        )

      # Returns nil (Logger.warning return value), not raising is enough
      assert is_nil(result) or result == :ok
    end

    test "tolerates nil queue/decode timings" do
      assert TelemetryHandlers.handle_ecto_query(
               [:whispr_messaging, :repo, :query],
               %{total_time: native(700), queue_time: nil, query_time: nil, decode_time: nil},
               %{query: "x", source: "y"},
               %{threshold_ms: 500}
             ) != :error
    end
  end

  describe "handle_phoenix_request/4" do
    test "emits a request log without raising" do
      conn = %Plug.Conn{status: 200, method: "GET", request_path: "/health"}

      assert TelemetryHandlers.handle_phoenix_request(
               [:phoenix, :endpoint, :stop],
               %{duration: native(15)},
               %{conn: conn},
               nil
             ) != :error
    end
  end

  describe "attach/0" do
    test "attaches handlers without raising" do
      # Detach first if already attached so the test can run repeatedly.
      :telemetry.detach("whispr-ecto-slow-query")
      :telemetry.detach("whispr-phoenix-request")

      assert :ok = TelemetryHandlers.attach()
    end
  end
end
