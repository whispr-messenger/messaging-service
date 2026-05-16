defmodule WhisprMessagingWeb.HealthHelpers do
  @moduledoc """
  Pure helpers extracted from `HealthController`. The original controller
  contained inline formatting and measurement helpers that were difficult
  to test from outside the supervision tree. These move them to a
  dependency-free module.
  """

  @doc """
  Runs `check_fn.()`, measures elapsed time, and returns a structured
  map with `:status` ("healthy" / "unhealthy"), the raw `:result`, and
  `:duration_ms`.
  """
  @spec measure_check((-> any())) :: %{
          status: String.t(),
          result: any(),
          duration_ms: integer()
        }
  def measure_check(check_fn) when is_function(check_fn, 0) do
    start_time = System.monotonic_time(:millisecond)
    result = check_fn.()
    duration = System.monotonic_time(:millisecond) - start_time

    status = if result == :ok, do: "healthy", else: "unhealthy"

    %{status: status, result: result, duration_ms: duration}
  end

  @doc """
  Renders an uptime in seconds as a human-readable string.
  The most significant non-zero unit determines the output shape.
  """
  @spec format_uptime(non_neg_integer()) :: String.t()
  def format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
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
end
