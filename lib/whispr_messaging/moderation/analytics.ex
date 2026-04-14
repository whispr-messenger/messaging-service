defmodule WhisprMessaging.Moderation.Analytics do
  @moduledoc """
  Analytics and statistics for the moderation system.

  Provides trends, top reported users, response times, category breakdowns,
  and comprehensive dashboard data for admin oversight of moderation activity.
  """

  import Ecto.Query

  alias WhisprMessaging.Moderation.Report
  alias WhisprMessaging.Repo

  require Logger

  # ---------------------------------------------------------------------------
  # Daily report trends
  # ---------------------------------------------------------------------------

  @doc """
  Returns report counts grouped by day for the last `days` days.

  ## Options
    * `days` - number of days to look back (default: 30)

  ## Returns
  A list of maps with `:date` and `:count` keys, ordered chronologically.

  ## Examples

      iex> Analytics.daily_report_counts(14)
      [%{date: ~D[2026-04-01], count: 5}, %{date: ~D[2026-04-02], count: 3}, ...]
  """
  @spec daily_report_counts(non_neg_integer()) :: [%{date: Date.t(), count: non_neg_integer()}]
  def daily_report_counts(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff,
      group_by: fragment("DATE(inserted_at)"),
      select: {fragment("DATE(inserted_at)"), count(r.id)},
      order_by: fragment("DATE(inserted_at)")
    )
    |> Repo.all()
    |> Enum.map(fn {date, count} -> %{date: date, count: count} end)
  end

  @doc """
  Returns report counts grouped by hour for the last `hours` hours.
  Useful for monitoring real-time spikes in report activity.

  ## Returns
  A list of maps with `:hour` (ISO 8601 truncated to hour) and `:count`.
  """
  @spec hourly_report_counts(non_neg_integer()) :: [%{hour: String.t(), count: non_neg_integer()}]
  def hourly_report_counts(hours \\ 24) do
    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3_600, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff,
      group_by: fragment("date_trunc('hour', inserted_at)"),
      select: {fragment("date_trunc('hour', inserted_at)"), count(r.id)},
      order_by: fragment("date_trunc('hour', inserted_at)")
    )
    |> Repo.all()
    |> Enum.map(fn {hour, count} ->
      %{hour: NaiveDateTime.to_iso8601(hour), count: count}
    end)
  end

  # ---------------------------------------------------------------------------
  # Category breakdown
  # ---------------------------------------------------------------------------

  @doc """
  Returns report counts grouped by category.

  ## Options
    * `:days` - restrict to the last N days (default: all time)
    * `:status` - filter by report status (e.g. "pending", "resolved_action")

  ## Returns
  A list of maps with `:category` and `:count`, ordered by count descending.
  """
  @spec category_breakdown(keyword()) :: [%{category: String.t(), count: non_neg_integer()}]
  def category_breakdown(opts \\ []) do
    days = Keyword.get(opts, :days)
    status = Keyword.get(opts, :status)

    query =
      Report
      |> maybe_filter_days(days)
      |> maybe_filter_status(status)

    from(r in query,
      group_by: r.category,
      select: {r.category, count(r.id)},
      order_by: [desc: count(r.id)]
    )
    |> Repo.all()
    |> Enum.map(fn {cat, count} -> %{category: cat, count: count} end)
  end

  @doc """
  Returns a percentage breakdown of categories for the given time range.
  Each entry includes `:category`, `:count`, and `:percentage`.
  """
  @spec category_percentages(keyword()) :: [
          %{category: String.t(), count: non_neg_integer(), percentage: float()}
        ]
  def category_percentages(opts \\ []) do
    breakdown = category_breakdown(opts)
    total = Enum.reduce(breakdown, 0, fn %{count: c}, acc -> acc + c end)

    Enum.map(breakdown, fn %{category: cat, count: count} ->
      pct = if total == 0, do: 0.0, else: Float.round(count / total * 100, 1)
      %{category: cat, count: count, percentage: pct}
    end)
  end

  # ---------------------------------------------------------------------------
  # Top reported users
  # ---------------------------------------------------------------------------

  @doc """
  Returns the most-reported users ranked by unique reporter count.

  ## Parameters
    * `limit` - max results (default: 10)
    * `days` - look-back window in days (default: 30)

  ## Returns
  A list of maps with `:user_id`, `:unique_reporters`, and `:total_reports`.
  """
  @spec top_reported_users(non_neg_integer(), non_neg_integer()) :: [
          %{
            user_id: String.t(),
            unique_reporters: non_neg_integer(),
            total_reports: non_neg_integer()
          }
        ]
  def top_reported_users(limit \\ 10, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff,
      group_by: r.reported_user_id,
      select: {r.reported_user_id, count(r.reporter_id, :distinct), count(r.id)},
      order_by: [desc: count(r.reporter_id, :distinct)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {user_id, unique_reporters, total_reports} ->
      %{user_id: user_id, unique_reporters: unique_reporters, total_reports: total_reports}
    end)
  end

  @doc """
  Returns the most active reporters (users who file the most reports).
  Useful for detecting potential report abuse.

  ## Parameters
    * `limit` - max results (default: 10)
    * `days` - look-back window in days (default: 30)
  """
  @spec top_reporters(non_neg_integer(), non_neg_integer()) :: [
          %{reporter_id: String.t(), report_count: non_neg_integer(), categories: [String.t()]}
        ]
  def top_reporters(limit \\ 10, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff,
      group_by: r.reporter_id,
      select: {r.reporter_id, count(r.id), fragment("array_agg(DISTINCT ?)", r.category)},
      order_by: [desc: count(r.id)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {reporter_id, count, categories} ->
      %{reporter_id: reporter_id, report_count: count, categories: categories}
    end)
  end

  # ---------------------------------------------------------------------------
  # Resolution metrics
  # ---------------------------------------------------------------------------

  @doc """
  Returns the average resolution time in hours for resolved reports.

  Only considers reports with status "resolved_action" or "resolved_dismissed".
  Resolution time is measured as `updated_at - inserted_at`.

  ## Parameters
    * `days` - look-back window in days (default: 30)

  ## Returns
  Average hours as a float rounded to 1 decimal, or 0.0 if no resolved reports.
  """
  @spec avg_resolution_time(non_neg_integer()) :: float()
  def avg_resolution_time(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    result =
      from(r in Report,
        where:
          r.inserted_at >= ^cutoff and
            r.status in ["resolved_action", "resolved_dismissed"],
        select: fragment("AVG(EXTRACT(EPOCH FROM (updated_at - inserted_at)) / 3600)")
      )
      |> Repo.one()

    case result do
      nil -> 0.0
      %Decimal{} = avg -> avg |> Decimal.to_float() |> Float.round(1)
      avg when is_float(avg) -> Float.round(avg, 1)
      avg when is_integer(avg) -> avg / 1.0
      _ -> 0.0
    end
  end

  @doc """
  Returns the median resolution time in hours.
  More robust than average for skewed distributions.
  """
  @spec median_resolution_time(non_neg_integer()) :: float()
  def median_resolution_time(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    result =
      from(r in Report,
        where:
          r.inserted_at >= ^cutoff and
            r.status in ["resolved_action", "resolved_dismissed"],
        select:
          fragment(
            "PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (updated_at - inserted_at)) / 3600)"
          )
      )
      |> Repo.one()

    case result do
      nil -> 0.0
      median when is_float(median) -> Float.round(median, 1)
      median -> Float.round(median * 1.0, 1)
    end
  end

  @doc """
  Returns the percentage of reports resolved out of total reports.

  ## Parameters
    * `days` - look-back window in days (default: 30)

  ## Returns
  A float percentage (0.0 - 100.0) rounded to 1 decimal.
  """
  @spec resolution_rate(non_neg_integer()) :: float()
  def resolution_rate(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    total =
      from(r in Report, where: r.inserted_at >= ^cutoff, select: count(r.id))
      |> Repo.one()

    resolved =
      from(r in Report,
        where:
          r.inserted_at >= ^cutoff and
            r.status in ["resolved_action", "resolved_dismissed"],
        select: count(r.id)
      )
      |> Repo.one()

    if total == 0, do: 0.0, else: Float.round(resolved / total * 100, 1)
  end

  # ---------------------------------------------------------------------------
  # Status distribution
  # ---------------------------------------------------------------------------

  @doc """
  Returns a map of status => count for reports in the given time range.

  ## Parameters
    * `days` - look-back window in days (default: 30)

  ## Returns
  A map like `%{"pending" => 42, "under_review" => 10, ...}`
  """
  @spec status_distribution(non_neg_integer()) :: %{String.t() => non_neg_integer()}
  def status_distribution(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff,
      group_by: r.status,
      select: {r.status, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Conversation hotspots
  # ---------------------------------------------------------------------------

  @doc """
  Returns conversations with the most reports, indicating moderation hotspots.

  ## Parameters
    * `limit` - max results (default: 10)
    * `days` - look-back window in days (default: 30)
  """
  @spec conversation_hotspots(non_neg_integer(), non_neg_integer()) :: [
          %{conversation_id: String.t(), report_count: non_neg_integer()}
        ]
  def conversation_hotspots(limit \\ 10, days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    from(r in Report,
      where: r.inserted_at >= ^cutoff and not is_nil(r.conversation_id),
      group_by: r.conversation_id,
      select: {r.conversation_id, count(r.id)},
      order_by: [desc: count(r.id)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn {conv_id, count} ->
      %{conversation_id: conv_id, report_count: count}
    end)
  end

  # ---------------------------------------------------------------------------
  # Comprehensive dashboard
  # ---------------------------------------------------------------------------

  @doc """
  Returns a comprehensive dashboard payload combining all analytics.

  This is the primary endpoint for the admin moderation dashboard,
  providing a single-request overview of the entire moderation system state.

  ## Returns
  A map containing:
    * `:daily_counts` - 14-day report trend
    * `:hourly_counts` - 24-hour report trend
    * `:category_breakdown` - 30-day category distribution
    * `:category_percentages` - 30-day category percentages
    * `:top_reported` - top 5 most-reported users (30 days)
    * `:top_reporters` - top 5 most-active reporters (30 days)
    * `:avg_resolution_hours` - mean resolution time (30 days)
    * `:median_resolution_hours` - median resolution time (30 days)
    * `:resolution_rate_pct` - resolution rate percentage (30 days)
    * `:status_distribution` - status counts (30 days)
    * `:conversation_hotspots` - top 5 conversations by report count (30 days)
  """
  @spec dashboard_stats() :: map()
  def dashboard_stats do
    Logger.info("[Analytics] Generating dashboard stats")

    %{
      daily_counts: daily_report_counts(14),
      hourly_counts: hourly_report_counts(24),
      category_breakdown: category_breakdown(days: 30),
      category_percentages: category_percentages(days: 30),
      top_reported: top_reported_users(5, 30),
      top_reporters: top_reporters(5, 30),
      avg_resolution_hours: avg_resolution_time(30),
      median_resolution_hours: median_resolution_time(30),
      resolution_rate_pct: resolution_rate(30),
      status_distribution: status_distribution(30),
      conversation_hotspots: conversation_hotspots(5, 30)
    }
  end

  @doc """
  Returns a lightweight summary suitable for sidebar widgets or notifications.
  Fewer queries than the full dashboard.
  """
  @spec quick_summary() :: map()
  def quick_summary do
    cutoff_30d = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)
    cutoff_24h = DateTime.utc_now() |> DateTime.add(-86_400, :second)

    total_30d =
      from(r in Report, where: r.inserted_at >= ^cutoff_30d, select: count(r.id))
      |> Repo.one()

    total_24h =
      from(r in Report, where: r.inserted_at >= ^cutoff_24h, select: count(r.id))
      |> Repo.one()

    pending =
      from(r in Report, where: r.status == "pending", select: count(r.id))
      |> Repo.one()

    %{
      total_reports_30d: total_30d,
      total_reports_24h: total_24h,
      pending_reports: pending,
      resolution_rate_pct: resolution_rate(30)
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_days(query, nil), do: query

  defp maybe_filter_days(query, days) when is_integer(days) and days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    from(r in query, where: r.inserted_at >= ^cutoff)
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    from(r in query, where: r.status == ^status)
  end
end
