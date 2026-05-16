defmodule WhisprMessaging.Moderation.ReportSchemaTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Moderation.Report

  describe "valid_categories/0 and valid_statuses/0" do
    test "expose enum lists" do
      assert "spam" in Report.valid_categories()
      assert "pending" in Report.valid_statuses()
    end
  end

  describe "changeset/2" do
    test "is invalid without required fields" do
      cs = Report.changeset(%Report{}, %{})
      refute cs.valid?
    end

    test "rejects an unknown category" do
      cs =
        Report.changeset(%Report{}, %{
          reporter_id: Ecto.UUID.generate(),
          reported_user_id: Ecto.UUID.generate(),
          category: "shenanigans"
        })

      refute cs.valid?
    end

    test "rejects self-reports" do
      uid = Ecto.UUID.generate()

      cs =
        Report.changeset(%Report{}, %{
          reporter_id: uid,
          reported_user_id: uid,
          category: "spam"
        })

      refute cs.valid?
    end

    test "accepts a valid report" do
      cs =
        Report.changeset(%Report{}, %{
          reporter_id: Ecto.UUID.generate(),
          reported_user_id: Ecto.UUID.generate(),
          category: "spam",
          description: "test"
        })

      assert cs.valid?
    end
  end

  describe "resolve_changeset/2" do
    test "requires status and resolution" do
      cs = Report.resolve_changeset(%Report{}, %{})
      refute cs.valid?
    end

    test "rejects an unknown status string" do
      cs =
        Report.resolve_changeset(%Report{}, %{
          status: "alien_state",
          resolution: %{"action" => "dismiss"}
        })

      refute cs.valid?
    end

    test "accepts resolved_action / resolved_dismissed" do
      for status <- ~w(resolved_action resolved_dismissed) do
        cs =
          Report.resolve_changeset(%Report{}, %{
            status: status,
            resolution: %{"action" => "dismiss"}
          })

        assert cs.valid?, "#{status} should be a valid resolve_changeset status"
      end
    end
  end

  describe "status_changeset/2" do
    test "rejects unknown status" do
      cs = Report.status_changeset(%Report{}, "unknown")
      refute cs.valid?
    end

    test "accepts a valid status" do
      cs = Report.status_changeset(%Report{}, "under_review")
      assert cs.valid?
    end
  end

  describe "query builders" do
    test "by_reporter returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.by_reporter(Ecto.UUID.generate())
    end

    test "by_reported_user returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.by_reported_user(Ecto.UUID.generate())
    end

    test "by_status returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.by_status("pending")
    end

    test "pending returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.pending()
    end

    test "recent_for_user returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.recent_for_user(Ecto.UUID.generate(), 7)
    end

    test "unique_reporters_count returns an Ecto.Query" do
      assert %Ecto.Query{} = Report.unique_reporters_count(Ecto.UUID.generate(), 30)
    end
  end
end
