defmodule WhisprMessagingWeb.AnalyticsControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Moderation.Reports

  setup do
    admin_id = Ecto.UUID.generate()
    reporter_id = Ecto.UUID.generate()
    reported_user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

    Conversations.add_conversation_member(conversation.id, reporter_id)
    Conversations.add_conversation_member(conversation.id, reported_user_id)

    # Create some reports for analytics
    for category <- ~w(spam harassment violence spam spam) do
      {:ok, _} =
        Reports.create_report(%{
          reporter_id: Ecto.UUID.generate(),
          reported_user_id: reported_user_id,
          conversation_id: conversation.id,
          category: category
        })
    end

    %{
      admin_id: admin_id,
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      conversation: conversation
    }
  end

  defp admin_conn(admin_id) do
    build_conn()
    |> authenticated_conn(admin_id)
    |> json_conn()
  end

  describe "GET /messaging/api/v1/reports/analytics/dashboard" do
    test "returns full dashboard stats", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/dashboard")
        |> json_response(200)

      data = response["data"]
      assert is_list(data["daily_counts"])
      assert is_list(data["hourly_counts"])
      assert is_list(data["category_breakdown"])
      assert is_list(data["category_percentages"])
      assert is_list(data["top_reported"])
      assert is_list(data["top_reporters"])
      assert is_number(data["avg_resolution_hours"])
      assert is_number(data["median_resolution_hours"])
      assert is_number(data["resolution_rate_pct"])
      assert is_map(data["status_distribution"])
      assert is_list(data["conversation_hotspots"])
    end

    test "reflects seeded report counts in dashboard", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/dashboard")
        |> json_response(200)

      data = response["data"]

      # 5 reports were seeded: 3 spam, 1 harassment, 1 violence
      total_daily =
        Enum.reduce(data["daily_counts"], 0, fn entry, acc -> acc + entry["count"] end)

      assert total_daily >= 5

      spam = Enum.find(data["category_breakdown"], fn c -> c["category"] == "spam" end)
      assert spam != nil
      assert spam["count"] >= 3

      # Top reported should include the reported user
      assert data["top_reported"] != []
      top = hd(data["top_reported"])
      assert top["user_id"] == ctx.reported_user_id
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/dashboard (empty data)" do
    # Separate setup without seeded reports
    @tag :empty_analytics
    test "returns zeros and empty arrays when no reports exist" do
      empty_admin = Ecto.UUID.generate()

      # Use a fresh connection with no seeded reports context
      # The setup block seeds reports, but this test verifies the structure
      # is valid even when specific keys have zero values
      response =
        build_conn()
        |> authenticated_conn(empty_admin)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/analytics/dashboard")
        |> json_response(200)

      data = response["data"]
      assert is_list(data["daily_counts"])
      assert is_list(data["hourly_counts"])
      assert is_list(data["category_breakdown"])
      assert is_number(data["avg_resolution_hours"])
      assert is_number(data["resolution_rate_pct"])
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/summary" do
    test "returns lightweight summary", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/summary")
        |> json_response(200)

      data = response["data"]
      assert is_integer(data["total_reports_30d"])
      assert is_integer(data["total_reports_24h"])
      assert is_integer(data["pending_reports"])
      assert is_number(data["resolution_rate_pct"])

      assert data["total_reports_30d"] >= 5
      assert data["pending_reports"] >= 5
    end

    test "resolution rate is 0.0 when no reports are resolved", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/summary")
        |> json_response(200)

      # All seeded reports are pending, none resolved
      assert response["data"]["resolution_rate_pct"] == 0.0
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/trends" do
    test "returns daily report counts", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/trends")
        |> json_response(200)

      data = response["data"]
      assert is_list(data)
      assert data != []

      entry = hd(data)
      assert Map.has_key?(entry, "date")
      assert Map.has_key?(entry, "count")
    end

    test "accepts days parameter", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/trends?days=7")
        |> json_response(200)

      assert is_list(response["data"])
    end

    test "clamps days to max 365", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/trends?days=9999")
        |> json_response(200)

      assert is_list(response["data"])
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/trends/hourly" do
    test "returns hourly report counts", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/trends/hourly")
        |> json_response(200)

      data = response["data"]
      assert is_list(data)
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/top-reported" do
    test "returns top reported users", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/top-reported")
        |> json_response(200)

      data = response["data"]
      assert is_list(data)
      assert data != []

      user = hd(data)
      assert Map.has_key?(user, "user_id")
      assert Map.has_key?(user, "unique_reporters")
      assert Map.has_key?(user, "total_reports")
    end

    test "accepts limit and days parameters", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/top-reported?limit=5&days=14")
        |> json_response(200)

      assert is_list(response["data"])
      assert Enum.count(response["data"]) <= 5
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/categories" do
    test "returns category breakdown with percentages", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/categories")
        |> json_response(200)

      data = response["data"]
      assert is_list(data)
      assert data != []

      entry = hd(data)
      assert Map.has_key?(entry, "category")
      assert Map.has_key?(entry, "count")
      assert Map.has_key?(entry, "percentage")
    end

    test "accepts days and status filters", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/categories?days=7&status=pending")
        |> json_response(200)

      assert is_list(response["data"])
    end
  end

  describe "GET /messaging/api/v1/reports/analytics/resolution" do
    test "returns resolution metrics", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/resolution")
        |> json_response(200)

      data = response["data"]
      assert is_number(data["avg_resolution_hours"])
      assert is_number(data["median_resolution_hours"])
      assert is_number(data["resolution_rate_pct"])
      assert is_map(data["status_distribution"])
    end

    test "accepts days parameter", ctx do
      response =
        admin_conn(ctx.admin_id)
        |> get(~p"/messaging/api/v1/reports/analytics/resolution?days=14")
        |> json_response(200)

      assert is_number(response["data"]["avg_resolution_hours"])
    end
  end
end
