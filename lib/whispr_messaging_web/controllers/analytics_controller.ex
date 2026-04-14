defmodule WhisprMessagingWeb.AnalyticsController do
  @moduledoc """
  HTTP controller for moderation analytics endpoints.

  Provides admin access to moderation statistics, trends, and reports
  for the moderation dashboard.

  NOTE: swagger_path functions are written manually (not via the swagger_path
  macro) because PhoenixSwagger.Path.summary/2 conflicts with this
  controller's own summary/2 action.
  """

  use WhisprMessagingWeb, :controller

  alias PhoenixSwagger.Path.PathObject
  alias WhisprMessaging.Moderation.Analytics

  action_fallback WhisprMessagingWeb.FallbackController

  # ---------------------------------------------------------------------------
  # Swagger path definitions (fully-qualified to avoid summary/2 conflict)
  # ---------------------------------------------------------------------------

  @doc false
  def swagger_path_dashboard(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/dashboard")
    |> PhoenixSwagger.Path.summary("Moderation dashboard")
    |> PhoenixSwagger.Path.description(
      "Returns comprehensive dashboard statistics including daily/hourly trends, category breakdown, top reported users, resolution metrics, and conversation hotspots. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :dashboard)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_summary(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/summary")
    |> PhoenixSwagger.Path.summary("Quick summary")
    |> PhoenixSwagger.Path.description(
      "Returns a lightweight summary suitable for sidebar widgets: total reports (30d and 24h), pending count, resolution rate. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :summary)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_trends(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/trends")
    |> PhoenixSwagger.Path.summary("Daily report trends")
    |> PhoenixSwagger.Path.description(
      "Returns daily report counts for the specified look-back window. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.parameter(
      :days,
      :query,
      :integer,
      "Look-back window in days (default: 30, max: 365)",
      required: false
    )
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :trends)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_trends_hourly(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/trends/hourly")
    |> PhoenixSwagger.Path.summary("Hourly report trends")
    |> PhoenixSwagger.Path.description(
      "Returns hourly report counts for the specified look-back window. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.parameter(
      :hours,
      :query,
      :integer,
      "Look-back window in hours (default: 24, max: 168)",
      required: false
    )
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :trends_hourly)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_top_reported(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/top-reported")
    |> PhoenixSwagger.Path.summary("Top reported users")
    |> PhoenixSwagger.Path.description(
      "Returns users with the most unique reporters. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.parameter(
      :limit,
      :query,
      :integer,
      "Maximum results (default: 10, max: 50)",
      required: false
    )
    |> PhoenixSwagger.Path.parameter(
      :days,
      :query,
      :integer,
      "Look-back window in days (default: 30, max: 365)",
      required: false
    )
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :top_reported)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_categories(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/categories")
    |> PhoenixSwagger.Path.summary("Category breakdown")
    |> PhoenixSwagger.Path.description(
      "Returns report counts and percentages grouped by category. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.parameter(
      :days,
      :query,
      :integer,
      "Look-back window in days (default: all time)",
      required: false
    )
    |> PhoenixSwagger.Path.parameter(:status, :query, :string, "Filter by report status",
      required: false,
      enum: [:pending, :reviewing, :resolved, :dismissed]
    )
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :categories)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  @doc false
  def swagger_path_resolution(route) do
    %PathObject{}
    |> PhoenixSwagger.Path.get("/reports/analytics/resolution")
    |> PhoenixSwagger.Path.summary("Resolution metrics")
    |> PhoenixSwagger.Path.description(
      "Returns resolution metrics: average time, median time, resolution rate, and status distribution. Admin only."
    )
    |> PhoenixSwagger.Path.produces("application/json")
    |> PhoenixSwagger.Path.tag("Moderation - Analytics")
    |> PhoenixSwagger.Path.parameter(
      :days,
      :query,
      :integer,
      "Look-back window in days (default: 30, max: 365)",
      required: false
    )
    |> PhoenixSwagger.Path.security([%{Bearer: []}])
    |> PhoenixSwagger.Path.response(200, "Success")
    |> PhoenixSwagger.ensure_operation_id(__MODULE__, :resolution)
    |> PhoenixSwagger.ensure_tag(__MODULE__)
    |> PhoenixSwagger.ensure_verb_and_path(route)
    |> PhoenixSwagger.Path.nest()
    |> PhoenixSwagger.to_json()
  end

  # ---------------------------------------------------------------------------
  # Dashboard (full stats)
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/dashboard

  Returns comprehensive dashboard statistics including daily/hourly trends,
  category breakdown, top reported users, resolution metrics, and more.
  """
  def dashboard(conn, _params) do
    stats = Analytics.dashboard_stats()

    json(conn, %{
      data: %{
        daily_counts: stats.daily_counts,
        hourly_counts: stats.hourly_counts,
        category_breakdown: stats.category_breakdown,
        category_percentages: stats.category_percentages,
        top_reported: stats.top_reported,
        top_reporters: stats.top_reporters,
        avg_resolution_hours: stats.avg_resolution_hours,
        median_resolution_hours: stats.median_resolution_hours,
        resolution_rate_pct: stats.resolution_rate_pct,
        status_distribution: stats.status_distribution,
        conversation_hotspots: stats.conversation_hotspots
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Quick summary (lightweight)
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/summary

  Returns a lightweight summary suitable for sidebar widgets:
  total reports (30d and 24h), pending count, resolution rate.
  """
  def summary(conn, _params) do
    result = Analytics.quick_summary()
    json(conn, %{data: result})
  end

  # ---------------------------------------------------------------------------
  # Trends
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/trends

  Returns daily report counts for the specified number of days.

  ## Query parameters
    * `days` - look-back window (default: 30, max: 365)
  """
  def trends(conn, params) do
    days = parse_bounded_int(params["days"], 30, 1, 365)
    counts = Analytics.daily_report_counts(days)
    json(conn, %{data: counts})
  end

  @doc """
  GET /messaging/api/v1/reports/analytics/trends/hourly

  Returns hourly report counts for the specified number of hours.

  ## Query parameters
    * `hours` - look-back window (default: 24, max: 168)
  """
  def trends_hourly(conn, params) do
    hours = parse_bounded_int(params["hours"], 24, 1, 168)
    counts = Analytics.hourly_report_counts(hours)
    json(conn, %{data: counts})
  end

  # ---------------------------------------------------------------------------
  # Top reported users
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/top-reported

  Returns users with the most unique reporters.

  ## Query parameters
    * `limit` - max results (default: 10, max: 50)
    * `days` - look-back window (default: 30, max: 365)
  """
  def top_reported(conn, params) do
    limit = parse_bounded_int(params["limit"], 10, 1, 50)
    days = parse_bounded_int(params["days"], 30, 1, 365)
    users = Analytics.top_reported_users(limit, days)
    json(conn, %{data: users})
  end

  # ---------------------------------------------------------------------------
  # Category breakdown
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/categories

  Returns report counts and percentages grouped by category.

  ## Query parameters
    * `days` - look-back window (default: all time)
    * `status` - filter by report status
  """
  def categories(conn, params) do
    opts =
      []
      |> maybe_add_opt(:days, parse_optional_int(params["days"]))
      |> maybe_add_opt(:status, params["status"])

    percentages = Analytics.category_percentages(opts)
    json(conn, %{data: percentages})
  end

  # ---------------------------------------------------------------------------
  # Resolution metrics
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/analytics/resolution

  Returns resolution metrics: average time, median time, and rate.

  ## Query parameters
    * `days` - look-back window (default: 30)
  """
  def resolution(conn, params) do
    days = parse_bounded_int(params["days"], 30, 1, 365)

    json(conn, %{
      data: %{
        avg_resolution_hours: Analytics.avg_resolution_time(days),
        median_resolution_hours: Analytics.median_resolution_time(days),
        resolution_rate_pct: Analytics.resolution_rate(days),
        status_distribution: Analytics.status_distribution(days)
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_bounded_int(nil, default, _min, _max), do: default

  defp parse_bounded_int(val, default, min_val, max_val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> max(min_val, min(int, max_val))
      :error -> default
    end
  end

  defp parse_bounded_int(val, _default, min_val, max_val) when is_integer(val) do
    max(min_val, min(val, max_val))
  end

  defp parse_bounded_int(_val, default, _min, _max), do: default

  defp parse_optional_int(nil), do: nil

  defp parse_optional_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_optional_int(val) when is_integer(val), do: val
  defp parse_optional_int(_), do: nil

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
