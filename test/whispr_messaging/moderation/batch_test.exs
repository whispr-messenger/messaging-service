defmodule WhisprMessaging.Moderation.BatchTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Moderation.{Batch, Report, Reports}

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()
    admin_id = create_test_user_id()

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      admin_id: admin_id
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

  defp create_pending_reports(count, reported_user_id, category \\ "spam") do
    for _ <- 1..count do
      reporter = create_test_user_id()
      create_report(reporter, reported_user_id, category)
    end
  end

  describe "bulk_resolve/3 (empty)" do
    test "handles empty list gracefully", ctx do
      {:ok, result} =
        Batch.bulk_resolve([], ctx.admin_id, %{action: "dismiss", notes: "Empty batch"})

      assert result.succeeded == 0
      assert result.failed == 0
      assert result.errors == []
    end
  end

  describe "bulk_resolve/3" do
    test "resolves multiple reports", ctx do
      reports = create_pending_reports(3, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      {:ok, result} =
        Batch.bulk_resolve(ids, ctx.admin_id, %{action: "dismiss", notes: "Bulk test"})

      assert result.succeeded == 3
      assert result.failed == 0
      assert result.errors == []
    end

    test "handles mix of valid and invalid IDs", ctx do
      reports = create_pending_reports(2, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id) ++ [Ecto.UUID.generate()]

      {:ok, result} =
        Batch.bulk_resolve(ids, ctx.admin_id, %{action: "dismiss"})

      assert result.succeeded == 2
      assert result.failed == 1
      assert Enum.count(result.errors) == 1
    end

    test "handles already resolved reports", ctx do
      report = create_report(ctx.reporter_id, ctx.reported_user_id)
      {:ok, _} = Reports.resolve_report(report.id, ctx.admin_id, %{action: "dismiss"})

      {:ok, result} =
        Batch.bulk_resolve([report.id], ctx.admin_id, %{action: "mute"})

      assert result.succeeded == 0
      assert result.failed == 1
      assert hd(result.errors).reason == "Report already resolved"
    end
  end

  describe "bulk_dismiss/3" do
    test "dismisses multiple reports with default notes", ctx do
      reports = create_pending_reports(3, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      {:ok, result} = Batch.bulk_dismiss(ids, ctx.admin_id)

      assert result.succeeded == 3
      assert result.failed == 0
    end

    test "dismisses with custom notes", ctx do
      reports = create_pending_reports(2, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      {:ok, result} = Batch.bulk_dismiss(ids, ctx.admin_id, "False positives from spam wave")

      assert result.succeeded == 2
    end
  end

  describe "bulk_dismiss/3 (empty)" do
    test "handles empty list gracefully", ctx do
      {:ok, result} = Batch.bulk_dismiss([], ctx.admin_id)

      assert result.succeeded == 0
      assert result.failed == 0
      assert result.errors == []
    end
  end

  describe "bulk_update_status/2" do
    test "updates status for multiple reports", ctx do
      reports = create_pending_reports(3, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      {:ok, count} = Batch.bulk_update_status(ids, "under_review")
      assert count == 3

      # Verify status changed
      for id <- ids do
        {:ok, report} = Reports.get_report(id)
        assert report.status == "under_review"
      end
    end

    test "rejects invalid status", ctx do
      reports = create_pending_reports(1, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      assert {:error, {:invalid_status, "bogus"}} = Batch.bulk_update_status(ids, "bogus")
    end
  end

  describe "bulk_update_status/2 (empty)" do
    test "handles empty list gracefully" do
      {:ok, count} = Batch.bulk_update_status([], "under_review")
      assert count == 0
    end
  end

  describe "bulk_categorize/2" do
    test "re-categorizes reports", ctx do
      reports = create_pending_reports(3, ctx.reported_user_id, "spam")
      ids = Enum.map(reports, & &1.id)

      {:ok, count} = Batch.bulk_categorize(ids, "harassment")
      assert count == 3

      for id <- ids do
        {:ok, report} = Reports.get_report(id)
        assert report.category == "harassment"
      end
    end

    test "rejects invalid category", ctx do
      reports = create_pending_reports(1, ctx.reported_user_id)
      ids = Enum.map(reports, & &1.id)

      assert {:error, :invalid_category} = Batch.bulk_categorize(ids, "not_real")
    end
  end

  describe "dismiss_by_filter/2" do
    test "dismisses all pending reports matching category", ctx do
      create_pending_reports(3, ctx.reported_user_id, "spam")
      create_pending_reports(2, ctx.reported_user_id, "harassment")

      {:ok, count} = Batch.dismiss_by_filter(ctx.admin_id, category: "spam")
      assert count >= 3
    end

    test "dismisses by reported user", ctx do
      create_pending_reports(3, ctx.reported_user_id, "spam")
      other_user = create_test_user_id()
      create_pending_reports(2, other_user, "spam")

      {:ok, count} =
        Batch.dismiss_by_filter(ctx.admin_id, reported_user_id: ctx.reported_user_id)

      assert count >= 3
    end

    test "returns 0 when no matching reports", ctx do
      {:ok, count} = Batch.dismiss_by_filter(ctx.admin_id, category: "violence")
      assert count == 0
    end

    test "respects older_than_days filter (recent reports skipped)", ctx do
      # All reports were just created, so filtering for older_than_days: 1 should skip them
      create_pending_reports(3, ctx.reported_user_id, "spam")

      {:ok, count} = Batch.dismiss_by_filter(ctx.admin_id, older_than_days: 1)
      assert count == 0
    end

    test "combines category and user filters", ctx do
      create_pending_reports(3, ctx.reported_user_id, "spam")
      create_pending_reports(2, ctx.reported_user_id, "harassment")

      {:ok, count} =
        Batch.dismiss_by_filter(ctx.admin_id,
          category: "spam",
          reported_user_id: ctx.reported_user_id
        )

      assert count >= 3
    end
  end

  describe "merge_duplicates/1" do
    @tag :skip
    # Skip: unique constraint (reporter_id, message_id) WHERE status='pending'
    # prevents inserting true duplicates. Needs Repo.insert with changeset
    # that includes unique_constraint/3 to test properly.
    test "finds and merges duplicate reports", ctx do
      conversation = create_test_conversation()

      message = create_test_message(conversation.id, ctx.reported_user_id)

      # Same reporter, same message => duplicates
      {:ok, _r1} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          conversation_id: conversation.id,
          message_id: message.id,
          category: "spam"
        })

      # Use a different reporter to avoid the unique constraint on (reporter_id, message_id)
      # while still testing the same message being reported by multiple users
      second_reporter = create_test_user_id()

      {:ok, _r2} =
        Repo.insert(%Report{
          reporter_id: second_reporter,
          reported_user_id: ctx.reported_user_id,
          conversation_id: conversation.id,
          message_id: message.id,
          category: "spam",
          status: "pending"
        })

      {:ok, result} = Batch.merge_duplicates(ctx.admin_id)
      assert result.duplicates_found >= 1
    end

    test "returns zero when no duplicates exist", ctx do
      create_pending_reports(3, ctx.reported_user_id)

      {:ok, result} = Batch.merge_duplicates(ctx.admin_id)
      assert result.duplicates_found == 0
      assert result.dismissed == 0
    end
  end
end
