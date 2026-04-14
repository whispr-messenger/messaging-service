defmodule WhisprMessaging.Moderation.Reports do
  @moduledoc """
  Context for managing moderation reports.

  Handles report creation with evidence snapshots, anti-abuse checks
  (rate limiting, cooldowns, no self-report), and report resolution by admins.
  """

  import Ecto.Query
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Moderation.Report
  alias WhisprMessaging.Repo

  require Logger

  @max_reports_per_hour 5
  @cooldown_hours 24

  @doc """
  Creates a report with an evidence snapshot of the message.
  Enforces anti-abuse rules: no self-report, rate limit, cooldown.
  """
  def create_report(attrs) do
    with :ok <- check_rate_limit(attrs.reporter_id),
         :ok <- check_cooldown(attrs.reporter_id, attrs[:message_id]),
         evidence <- build_evidence(attrs[:message_id]),
         attrs <- Map.put(attrs, :evidence, evidence) do
      %Report{}
      |> Report.changeset(attrs)
      |> Repo.insert()
      |> tap_ok(fn report ->
        Logger.info(
          "Report #{report.id} created by #{report.reporter_id} against #{report.reported_user_id}"
        )

        publish_report_created(report)
        check_escalation_thresholds(report.reported_user_id)
      end)
    end
  end

  @doc """
  Lists reports submitted by a user (paginated).
  """
  def list_my_reports(reporter_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    Report
    |> Report.by_reporter(reporter_id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Lists pending reports for admin review (paginated, filterable).
  """
  def list_report_queue(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status, "pending")
    category = Keyword.get(opts, :category)

    Report
    |> Report.by_status(status)
    |> maybe_filter_category(category)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Gets a single report by ID.
  """
  def get_report(id) do
    case Repo.get(Report, id) do
      nil -> {:error, :not_found}
      report -> {:ok, report}
    end
  end

  @doc """
  Resolves a report (admin action). Sets status and resolution details.
  """
  def resolve_report(report_id, admin_id, resolution_attrs) do
    with {:ok, report} <- get_report(report_id),
         :ok <- validate_resolvable(report) do
      resolution = %{
        action: resolution_attrs.action,
        resolved_by: admin_id,
        resolved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        notes: Map.get(resolution_attrs, :notes, "")
      }

      status =
        case resolution_attrs.action do
          "dismiss" -> "resolved_dismissed"
          _ -> "resolved_action"
        end

      report
      |> Report.resolve_changeset(%{status: status, resolution: resolution})
      |> Repo.update()
      |> tap_ok(fn resolved ->
        Logger.info("Report #{resolved.id} resolved by #{admin_id}: #{status}")
      end)
    end
  end

  @doc """
  Returns report statistics for admin dashboard.
  """
  def get_stats do
    pending = Repo.aggregate(Report.pending(), :count, :id)
    under_review = Repo.aggregate(Report.by_status("under_review"), :count, :id)
    resolved_today = count_resolved_today()

    by_category =
      from(r in Report,
        where: r.status == "pending",
        group_by: r.category,
        select: {r.category, count(r.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      pending: pending,
      under_review: under_review,
      resolved_today: resolved_today,
      by_category: by_category
    }
  end

  @doc """
  Counts unique reporters for a user in a given number of days.
  Used by auto-escalation.
  """
  def unique_reporter_count(reported_user_id, days) do
    Report.unique_reporters_count(reported_user_id, days)
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Anti-abuse checks
  # ---------------------------------------------------------------------------

  defp check_rate_limit(reporter_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3_600, :second)

    count =
      from(r in Report,
        where: r.reporter_id == ^reporter_id and r.inserted_at >= ^one_hour_ago,
        select: count(r.id)
      )
      |> Repo.one()

    if count >= @max_reports_per_hour do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp check_cooldown(_reporter_id, nil), do: :ok

  defp check_cooldown(reporter_id, message_id) do
    cooldown_ago = DateTime.utc_now() |> DateTime.add(-@cooldown_hours * 3_600, :second)

    existing =
      from(r in Report,
        where:
          r.reporter_id == ^reporter_id and
            r.message_id == ^message_id and
            r.inserted_at >= ^cooldown_ago,
        select: count(r.id)
      )
      |> Repo.one()

    if existing > 0 do
      {:error, :cooldown_active}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence snapshot
  # ---------------------------------------------------------------------------

  defp build_evidence(nil), do: %{}

  defp build_evidence(message_id) do
    case Messages.get_message(message_id) do
      {:ok, message} ->
        %{
          message_id: message.id,
          sender_id: message.sender_id,
          conversation_id: message.conversation_id,
          message_type: message.message_type,
          content_snapshot: if(message.content, do: Base.encode64(message.content), else: nil),
          metadata: message.metadata,
          sent_at: message.sent_at && DateTime.to_iso8601(message.sent_at),
          captured_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      _ ->
        %{message_id: message_id, error: "message_not_found"}
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-escalation threshold check
  # ---------------------------------------------------------------------------

  defp check_escalation_thresholds(reported_user_id) do
    # These are checked async to not block the report creation response
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      do_check_escalation(reported_user_id)
    end)
  end

  defp do_check_escalation(reported_user_id) do
    mute_threshold = escalation_config(:mute_threshold, 3)
    mute_days = escalation_config(:mute_days, 7)
    ban_threshold = escalation_config(:ban_threshold, 5)
    ban_days = escalation_config(:ban_days, 14)
    review_threshold = escalation_config(:review_threshold, 10)
    review_days = escalation_config(:review_days, 30)

    count_7d = unique_reporter_count(reported_user_id, mute_days)
    count_14d = unique_reporter_count(reported_user_id, ban_days)
    count_30d = unique_reporter_count(reported_user_id, review_days)

    cond do
      count_30d >= review_threshold ->
        publish_threshold_reached(reported_user_id, :permanent_review, count_30d)

      count_14d >= ban_threshold ->
        publish_threshold_reached(reported_user_id, :temp_ban, count_14d)

      count_7d >= mute_threshold ->
        publish_threshold_reached(reported_user_id, :auto_mute, count_7d)

      true ->
        :ok
    end
  end

  defp escalation_config(key, default) do
    Application.get_env(:whispr_messaging, :moderation, [])
    |> Keyword.get(key, default)
  end

  # ---------------------------------------------------------------------------
  # Redis pub/sub events
  # ---------------------------------------------------------------------------

  defp publish_report_created(report) do
    payload =
      Jason.encode!(%{
        event: "report_created",
        report_id: report.id,
        reporter_id: report.reporter_id,
        reported_user_id: report.reported_user_id,
        category: report.category,
        conversation_id: report.conversation_id
      })

    Redix.command(:redix, ["PUBLISH", "whispr:moderation:report_created", payload])
  end

  defp publish_threshold_reached(reported_user_id, level, count) do
    payload =
      Jason.encode!(%{
        event: "threshold_reached",
        reported_user_id: reported_user_id,
        threshold_level: to_string(level),
        report_count: count
      })

    Redix.command(:redix, ["PUBLISH", "whispr:moderation:threshold_reached", payload])

    Logger.warning(
      "Moderation threshold #{level} reached for user #{reported_user_id} (#{count} unique reporters)"
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_category(query, nil), do: query

  defp maybe_filter_category(query, category),
    do: from(r in query, where: r.category == ^category)

  defp count_resolved_today do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    from(r in Report,
      where:
        r.status in ["resolved_action", "resolved_dismissed"] and r.updated_at >= ^today_start,
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp validate_resolvable(%Report{status: status}) when status in ~w(pending under_review),
    do: :ok

  defp validate_resolvable(_), do: {:error, :already_resolved}

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(error, _fun), do: error
end
