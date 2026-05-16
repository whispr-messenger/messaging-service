defmodule WhisprMessagingWeb.ReportHelpersTest do
  @moduledoc """
  Unit tests for the pure helpers extracted from `ReportController`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.ReportHelpers

  describe "serialize_report/1" do
    test "emits ISO8601 timestamps when inserted_at and updated_at are present" do
      report = %{
        id: "r-1",
        reporter_id: "u-1",
        reported_user_id: "u-2",
        conversation_id: "c-1",
        message_id: "m-1",
        category: "spam",
        description: "test",
        evidence: %{},
        status: "open",
        resolution: nil,
        auto_escalated: false,
        inserted_at: ~N[2026-05-01 10:00:00],
        updated_at: ~N[2026-05-02 11:00:00]
      }

      out = ReportHelpers.serialize_report(report)

      assert out.id == "r-1"
      assert out.category == "spam"
      assert out.created_at == "2026-05-01T10:00:00"
      assert out.updated_at == "2026-05-02T11:00:00"
    end

    test "passes through nil timestamps without crashing" do
      report = %{
        id: "r-2",
        reporter_id: nil,
        reported_user_id: nil,
        conversation_id: nil,
        message_id: nil,
        category: "harassment",
        description: nil,
        evidence: nil,
        status: "open",
        resolution: nil,
        auto_escalated: nil,
        inserted_at: nil,
        updated_at: nil
      }

      out = ReportHelpers.serialize_report(report)
      assert out.created_at == nil
      assert out.updated_at == nil
    end
  end

  describe "format_changeset_errors/1" do
    test "interpolates placeholders from option values" do
      types = %{title: :string}

      changeset =
        Ecto.Changeset.cast({%{}, types}, %{title: ""}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      errors = ReportHelpers.format_changeset_errors(changeset)
      assert Map.has_key?(errors, :title)
      assert ["can't be blank"] = errors.title
    end

    test "interpolates count placeholder via opts" do
      types = %{title: :string}

      changeset =
        Ecto.Changeset.cast({%{}, types}, %{title: "ab"}, [:title])
        |> Ecto.Changeset.validate_length(:title, min: 5)

      %{title: [msg | _]} = ReportHelpers.format_changeset_errors(changeset)
      assert msg =~ "5"
    end

    test "non-changeset errors fall through to inspect/1" do
      assert ReportHelpers.format_changeset_errors({:error, :weird}) =~ "weird"
      assert ReportHelpers.format_changeset_errors(:atom_err) == ":atom_err"
    end
  end

  describe "fallback_admin_check/1" do
    setup do
      original = System.get_env("ADMIN_USER_IDS")

      on_exit(fn ->
        case original do
          nil -> System.delete_env("ADMIN_USER_IDS")
          value -> System.put_env("ADMIN_USER_IDS", value)
        end
      end)

      :ok
    end

    test "returns false when ADMIN_USER_IDS is unset" do
      System.delete_env("ADMIN_USER_IDS")
      refute ReportHelpers.fallback_admin_check("anyone")
    end

    test "returns true when user_id is in the comma-separated list" do
      System.put_env("ADMIN_USER_IDS", "u-1, u-2 ,u-3")
      assert ReportHelpers.fallback_admin_check("u-2")
    end

    test "returns false for users not in the list" do
      System.put_env("ADMIN_USER_IDS", "u-1,u-2")
      refute ReportHelpers.fallback_admin_check("u-stranger")
    end

    test "trims whitespace around ids" do
      System.put_env("ADMIN_USER_IDS", "  u-1  ,  u-2  ")
      assert ReportHelpers.fallback_admin_check("u-1")
      assert ReportHelpers.fallback_admin_check("u-2")
    end
  end

  describe "admin_role?/1" do
    test "admin is admin" do
      assert ReportHelpers.admin_role?("admin")
    end

    test "moderator is admin" do
      assert ReportHelpers.admin_role?("moderator")
    end

    test "regular user is not admin" do
      refute ReportHelpers.admin_role?("user")
    end

    test "nil is not admin" do
      refute ReportHelpers.admin_role?(nil)
    end

    test "non-string role is not admin" do
      refute ReportHelpers.admin_role?(42)
      refute ReportHelpers.admin_role?(%{})
    end
  end

  describe "role_from_cache/1" do
    test "JSON-wrapped admin role → :admin" do
      assert ReportHelpers.role_from_cache({:ok, %{"role" => "admin"}}) == :admin
      assert ReportHelpers.role_from_cache({:ok, %{"role" => "moderator"}}) == :admin
    end

    test "plain admin string → :admin" do
      assert ReportHelpers.role_from_cache({:ok, "admin"}) == :admin
      assert ReportHelpers.role_from_cache({:ok, "moderator"}) == :admin
    end

    test "non-admin cache hit → :other" do
      assert ReportHelpers.role_from_cache({:ok, "user"}) == :other
      assert ReportHelpers.role_from_cache({:ok, %{"role" => "user"}}) == :other
    end

    test "cache miss → :miss" do
      assert ReportHelpers.role_from_cache({:error, :not_found}) == :miss
      assert ReportHelpers.role_from_cache(nil) == :miss
    end
  end

  describe "parse_int/2" do
    test "returns default for nil" do
      assert ReportHelpers.parse_int(nil, 10) == 10
    end

    test "parses a valid integer string" do
      assert ReportHelpers.parse_int("42", 0) == 42
    end

    test "parses with trailing garbage (Integer.parse keeps the int)" do
      assert ReportHelpers.parse_int("17abc", 0) == 17
    end

    test "returns default for unparseable string" do
      assert ReportHelpers.parse_int("not a number", 99) == 99
    end

    test "passes through an integer value" do
      assert ReportHelpers.parse_int(7, 0) == 7
    end

    test "falls back to default for a list (e.g. repeated query param)" do
      assert ReportHelpers.parse_int(["1", "2"], 5) == 5
    end

    test "falls back to default for a map (e.g. nested query param)" do
      assert ReportHelpers.parse_int(%{"x" => 1}, 5) == 5
    end

    test "falls back to default for an atom" do
      assert ReportHelpers.parse_int(:something, 5) == 5
    end
  end
end
