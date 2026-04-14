defmodule WhisprMessaging.Moderation.ReportsTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Moderation.{Report, Reports}

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()
    conversation = create_test_conversation()

    message = create_test_message(conversation.id, reported_user_id)

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      conversation: conversation,
      message: message
    }
  end

  describe "create_report/1" do
    test "creates a report with valid attributes", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reported_user_id,
        conversation_id: ctx.conversation.id,
        message_id: ctx.message.id,
        category: "spam",
        description: "This is spam"
      }

      assert {:ok, report} = Reports.create_report(attrs)
      assert report.reporter_id == ctx.reporter_id
      assert report.reported_user_id == ctx.reported_user_id
      assert report.category == "spam"
      assert report.status == "pending"
      assert report.evidence != %{}
    end

    test "rejects self-reporting", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reporter_id,
        category: "spam"
      }

      assert {:error, changeset} = Reports.create_report(attrs)
      assert "cannot report yourself" in errors_on(changeset).reported_user_id
    end

    test "rejects invalid category", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reported_user_id,
        category: "invalid_category"
      }

      assert {:error, changeset} = Reports.create_report(attrs)
      assert errors_on(changeset).category != []
    end

    test "enforces rate limit", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reported_user_id,
        category: "spam"
      }

      for _ <- 1..5 do
        assert {:ok, _} = Reports.create_report(attrs)
      end

      assert {:error, :rate_limited} = Reports.create_report(attrs)
    end

    test "enforces cooldown on same message", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reported_user_id,
        conversation_id: ctx.conversation.id,
        message_id: ctx.message.id,
        category: "spam"
      }

      assert {:ok, _} = Reports.create_report(attrs)
      assert {:error, :cooldown_active} = Reports.create_report(attrs)
    end
  end

  describe "list_my_reports/2" do
    test "returns reports for the authenticated user", ctx do
      attrs = %{
        reporter_id: ctx.reporter_id,
        reported_user_id: ctx.reported_user_id,
        category: "harassment"
      }

      {:ok, _} = Reports.create_report(attrs)
      {:ok, _} = Reports.create_report(%{attrs | category: "spam"})

      reports = Reports.list_my_reports(ctx.reporter_id)
      assert Enum.count(reports) == 2
    end

    test "does not return other users' reports", ctx do
      other_user = create_test_user_id()

      attrs = %{
        reporter_id: other_user,
        reported_user_id: ctx.reported_user_id,
        category: "spam"
      }

      {:ok, _} = Reports.create_report(attrs)

      reports = Reports.list_my_reports(ctx.reporter_id)
      assert reports == []
    end
  end

  describe "resolve_report/3" do
    test "resolves a pending report with dismiss action", ctx do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          category: "spam"
        })

      admin_id = create_test_user_id()

      assert {:ok, resolved} =
               Reports.resolve_report(report.id, admin_id, %{
                 action: "dismiss",
                 notes: "False positive"
               })

      assert resolved.status == "resolved_dismissed"
      resolution = resolved.resolution

      assert (resolution["resolved_by"] || resolution[:resolved_by]) == admin_id
      assert (resolution["action"] || resolution[:action]) == "dismiss"
    end

    test "resolves a pending report with action", ctx do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          category: "harassment"
        })

      admin_id = create_test_user_id()

      assert {:ok, resolved} =
               Reports.resolve_report(report.id, admin_id, %{
                 action: "mute",
                 notes: "Confirmed harassment"
               })

      assert resolved.status == "resolved_action"
    end

    test "cannot resolve already resolved report", ctx do
      {:ok, report} =
        Reports.create_report(%{
          reporter_id: ctx.reporter_id,
          reported_user_id: ctx.reported_user_id,
          category: "spam"
        })

      admin_id = create_test_user_id()
      {:ok, _} = Reports.resolve_report(report.id, admin_id, %{action: "dismiss"})

      assert {:error, :already_resolved} =
               Reports.resolve_report(report.id, admin_id, %{action: "mute"})
    end
  end

  describe "get_stats/0" do
    test "returns correct counts", ctx do
      for _ <- 1..3 do
        {:ok, _} =
          Reports.create_report(%{
            reporter_id: create_test_user_id(),
            reported_user_id: ctx.reported_user_id,
            category: "spam"
          })
      end

      stats = Reports.get_stats()
      assert stats.pending >= 3
      assert is_map(stats.by_category)
    end
  end

  describe "unique_reporter_count/2" do
    test "counts distinct reporters", ctx do
      for _ <- 1..3 do
        {:ok, _} =
          Reports.create_report(%{
            reporter_id: create_test_user_id(),
            reported_user_id: ctx.reported_user_id,
            category: "spam"
          })
      end

      count = Reports.unique_reporter_count(ctx.reported_user_id, 7)
      assert count == 3
    end
  end
end
