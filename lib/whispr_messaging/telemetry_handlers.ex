defmodule WhisprMessaging.TelemetryHandlers do
  @moduledoc """
  Attaches telemetry handlers that emit structured log entries for
  Phoenix requests and Ecto slow queries.
  """

  require Logger

  @slow_query_threshold_ms 500

  @doc """
  Attaches all telemetry handlers. Call once at application startup.
  """
  def attach do
    :telemetry.attach(
      "whispr-ecto-slow-query",
      [:whispr_messaging, :repo, :query],
      &__MODULE__.handle_ecto_query/4,
      %{threshold_ms: @slow_query_threshold_ms}
    )

    :telemetry.attach(
      "whispr-phoenix-request",
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_phoenix_request/4,
      nil
    )
  end

  @doc false
  def handle_ecto_query(_event, measurements, metadata, config) do
    total_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)

    if total_ms >= config.threshold_ms do
      Logger.warning("Slow query detected",
        query: metadata.query,
        source: metadata.source,
        total_time_ms: total_ms,
        queue_time_ms: convert_time(measurements[:queue_time]),
        query_time_ms: convert_time(measurements[:query_time]),
        decode_time_ms: convert_time(measurements[:decode_time]),
        domain: :ecto
      )
    end
  end

  @doc false
  def handle_phoenix_request(_event, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("Request completed",
      status: metadata.conn.status,
      method: metadata.conn.method,
      path: metadata.conn.request_path,
      duration_ms: duration_ms,
      domain: :phoenix
    )
  end

  defp convert_time(nil), do: 0
  defp convert_time(time), do: System.convert_time_unit(time, :native, :millisecond)
end
