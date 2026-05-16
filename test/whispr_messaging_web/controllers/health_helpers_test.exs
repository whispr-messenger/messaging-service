defmodule WhisprMessagingWeb.HealthHelpersTest do
  @moduledoc """
  Unit tests for the pure helpers extracted from `HealthController`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.HealthHelpers

  describe "measure_check/1" do
    test "tags an :ok result as 'healthy'" do
      result = HealthHelpers.measure_check(fn -> :ok end)
      assert result.status == "healthy"
      assert result.result == :ok
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0
    end

    test "tags a non-:ok result as 'unhealthy'" do
      result = HealthHelpers.measure_check(fn -> {:error, :nope} end)
      assert result.status == "unhealthy"
      assert result.result == {:error, :nope}
    end

    test "measures a slow call (>= 5 ms)" do
      result =
        HealthHelpers.measure_check(fn ->
          Process.sleep(5)
          :ok
        end)

      assert result.duration_ms >= 5
    end
  end

  describe "format_uptime/1" do
    test "0 seconds formats as '0s'" do
      assert HealthHelpers.format_uptime(0) == "0s"
    end

    test "less than a minute → seconds only" do
      assert HealthHelpers.format_uptime(45) == "45s"
    end

    test "exactly a minute" do
      assert HealthHelpers.format_uptime(60) == "1m 0s"
    end

    test "minutes-and-seconds" do
      assert HealthHelpers.format_uptime(90) == "1m 30s"
    end

    test "hours format" do
      assert HealthHelpers.format_uptime(3600) == "1h 0m 0s"
    end

    test "hours and minutes and seconds" do
      assert HealthHelpers.format_uptime(3661) == "1h 1m 1s"
    end

    test "days format" do
      assert HealthHelpers.format_uptime(86_400) == "1d 0h 0m 0s"
    end

    test "days/hours/minutes/seconds full" do
      assert HealthHelpers.format_uptime(90_061) == "1d 1h 1m 1s"
    end
  end
end
