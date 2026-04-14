defmodule WhisprMessaging.Moderation.AnalyticsTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Moderation.{Analytics, Reports}

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id
    }
  end

  defp create_report(reporter_id, reported_user_id, category \\ "spam") do
    {:ok, report} =
      Reports.create_report(%{
        reporter_id: reporter_id,
        reported_user_id: reported_user_id,
        category: category
      })

    report
  end

  defp create_reports(count, reported_user_id, category \\ "spam") do
    for _ <- 1..count do
      reporter = create_test_user_id()
      create_report(reporter, reported_user_id, category)
    end
  end

  describe "daily_report_counts/1" do
    test "returns empty list when no reports exist" do
      assert Analytics.daily_report_counts(7) == []
    end

    test "returns counts grouped by day", ctx do
      create_reports(3, ctx.reported_user_id)

      counts = Analytics.daily_report_counts(7)
      assert length(counts) >= 1

      today_entry = List.last(counts)
      assert today_entry.count >= 3
      assert %Date{} = today_entry.date
    end

    test "respects days parameter", ctx do
      create_reports(2, ctx.reported_user_id)

      counts_30 = Analytics.daily_report_counts(30)
      counts_1 = Analytics.daily_report_counts(1)

      # Both should return today's reports
      assert length(counts_30) >= 1
      assert length(counts_1) >= 1
    end
  end

  describe "hourly_report_counts/1" do
    test "returns counts grouped by hour", ctx do
      create_reports(2, ctx.reported_user_id)

      counts = Analytics.hourly_report_counts(24)
      assert length(counts) >= 1

      entry = List.last(counts)
      assert entry.count >= 2
      assert is_binary(entry.hour)
    end
  end

  describe "category_breakdown/1" do
    test "returns counts per category", ctx do
      create_reports(3, ctx.reported_user_id, "spam")
      create_reports(2, ctx.reported_user_id, "harassment")

      breakdown = Analytics.category_breakdown()
      spam = Enum.find(breakdown, fn b -> b.category == "spam" end)
      harassment = Enum.find(breakdown, fn b -> b.category == "harassment" end)

      assert spam.count >= 3
      assert harassment.count >= 2
    end

    test "filters by days", ctx do
      create_reports(2, ctx.reported_user_id, "offensive")
      breakdown = Analytics.category_breakdown(days: 7)
      assert length(breakdown) >= 1
    end

    test "filters by status", ctx do
      create_reports(2, ctx.reported_user_id, "spam")
      breakdown = Analytics.category_breakdown(status: "pending")
      assert length(breakdown) >= 1

      # No resolved reports yet
      resolved_breakdown = Analytics.category_breakdown(status: "resolved_action")
      resolved_count = Enum.reduce(resolved_breakdown, 0, fn b, acc -> acc + b.count end)
      assert resolved_count == 0
    end
  end

  describe "category_percentages/1" do
    test "returns percentages summing to ~100%", ctx do
      create_reports(3, ctx.reported_user_id, "spam")
      create_reports(2, ctx.reported_user_id, "harassment")
      create_reports(1, ctx.reported_user_id, "violence")

      percentages = Analytics.category_percentages(days: 30)
      total_pct = Enum.reduce(percentages, 0.0, fn p, acc -> acc + p.percentage end)

      # Should be close to 100% (may not be exact due to rounding)
      assert_in_delta total_pct, 100.0, 1.0

      Enum.each(percentages, fn p ->
        assert Map.has_key?(p, :category)
        assert Map.has_key?(p, :count)
        assert Map.has_key?(p, :percentage)
      end)
    end
  end

  describe "top_reported_users/2" do
    test "ranks users by unique reporter count", ctx do
      # User A gets reported by 3 unique reporters
      create_reports(3, ctx.reported_user_id, "spam")

      # User B gets reported by 1 reporter
      other_user = create_test_user_id()
      create_report(create_test_user_id(), other_user, "spam")

      top = Analytics.top_reported_users(10, 30)
      assert length(top) >= 2

      first = hd(top)
      assert first.user_id == ctx.reported_user_id
      assert first.unique_reporters >= 3
      assert first.total_reports >= 3
    end

    test "respects limit", ctx do
      create_reports(2, ctx.reported_user_id)
      top = Analytics.top_reported_users(1, 30)
      assert length(top) <= 1
    end
  end

  describe "top_reporters/2" do
    test "ranks reporters by report count", ctx do
      # Reporter creates multiple reports
      create_report(ctx.reporter_id, ctx.reported_user_id, "spam")
      create_report(ctx.reporter_id, create_test_user_id(), "harassment")

      top = Analytics.top_reporters(10, 30)
      assert length(top) >= 1

      reporter_entry = Enum.find(top, fn r -> r.reporter_id == ctx.reporter_id end)
      assert reporter_entry != nil
      assert reporter_entry.report_count >= 2
      assert is_list(reporter_entry.categories)
    end
  end

  describe "avg_resolution_time/1" do
    test "returns 0.0 when no resolved reports" do
      assert Analytics.avg_resolution_time(30) == 0.0
    end

    test "returns average for resolved reports", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id, "spam")
      admin_id = create_test_user_id()
      {:ok, _} = Reports.resolve_report(report.id, admin_id, %{action: "dismiss"})

      avg = Analytics.avg_resolution_time(30)
      assert is_float(avg)
      assert avg >= 0.0
    end
  end

  describe "median_resolution_time/1" do
    test "returns 0.0 when no resolved reports" do
      assert Analytics.median_resolution_time(30) == 0.0
    end

    test "returns median for resolved reports", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id, "spam")
      admin_id = create_test_user_id()
      {:ok, _} = Reports.resolve_report(report.id, admin_id, %{action: "dismiss"})

      median = Analytics.median_resolution_time(30)
      assert is_float(median)
      assert median >= 0.0
    end
  end

  describe "resolution_rate/1" do
    test "returns 0.0 when no reports" do
      assert Analytics.resolution_rate(30) == 0.0
    end

    test "returns correct rate", ctx do
      r1 = create_report(ctx.reporter_id, ctx.reported_user_id, "spam")
      _r2 = create_report(create_test_user_id(), ctx.reported_user_id, "harassment")

      admin_id = create_test_user_id()
      {:ok, _} = Reports.resolve_report(r1.id, admin_id, %{action: "dismiss"})

      rate = Analytics.resolution_rate(30)
      assert is_float(rate)
      assert rate > 0.0
      assert rate <= 100.0
    end
  end

  describe "status_distribution/1" do
    test "returns status counts as a map", ctx do
      create_reports(3, ctx.reported_user_id, "spam")

      dist = Analytics.status_distribution(30)
      assert is_map(dist)
      assert Map.get(dist, "pending", 0) >= 3
    end
  end

  describe "conversation_hotspots/2" do
    test "returns conversations ranked by report count", ctx do
      conversation = create_test_conversation()

      for _ <- 1..3 do
        reporter = create_test_user_id()

        {:ok, _} =
          Reports.create_report(%{
            reporter_id: reporter,
            reported_user_id: ctx.reported_user_id,
            conversation_id: conversation.id,
            category: "spam"
          })
      end

      hotspots = Analytics.conversation_hotspots(10, 30)
      assert length(hotspots) >= 1

      entry = Enum.find(hotspots, fn h -> h.conversation_id == conversation.id end)
      assert entry != nil
      assert entry.report_count >= 3
    end
  end

  describe "dashboard_stats/0" do
    test "returns all dashboard fields", ctx do
      create_reports(2, ctx.reported_user_id, "spam")

      stats = Analytics.dashboard_stats()
      assert Map.has_key?(stats, :daily_counts)
      assert Map.has_key?(stats, :hourly_counts)
      assert Map.has_key?(stats, :category_breakdown)
      assert Map.has_key?(stats, :category_percentages)
      assert Map.has_key?(stats, :top_reported)
      assert Map.has_key?(stats, :top_reporters)
      assert Map.has_key?(stats, :avg_resolution_hours)
      assert Map.has_key?(stats, :median_resolution_hours)
      assert Map.has_key?(stats, :resolution_rate_pct)
      assert Map.has_key?(stats, :status_distribution)
      assert Map.has_key?(stats, :conversation_hotspots)
    end
  end

  describe "quick_summary/0" do
    test "returns summary fields", ctx do
      create_reports(2, ctx.reported_user_id)

      summary = Analytics.quick_summary()
      assert Map.has_key?(summary, :total_reports_30d)
      assert Map.has_key?(summary, :total_reports_24h)
      assert Map.has_key?(summary, :pending_reports)
      assert Map.has_key?(summary, :resolution_rate_pct)

      assert summary.total_reports_30d >= 2
      assert summary.total_reports_24h >= 2
      assert summary.pending_reports >= 2
    end
  end
end
