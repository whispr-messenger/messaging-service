defmodule WhisprMessagingWeb.PresenceHelpersTest do
  @moduledoc """
  Unit tests for the pure presence helpers extracted from `Presence`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.PresenceHelpers

  describe "current_status/1" do
    test "empty list folds to 'offline'" do
      assert PresenceHelpers.current_status([]) == "offline"
    end

    test "single online → online" do
      assert PresenceHelpers.current_status([%{status: "online"}]) == "online"
    end

    test "single away → away" do
      assert PresenceHelpers.current_status([%{status: "away"}]) == "away"
    end

    test "single busy → busy" do
      assert PresenceHelpers.current_status([%{status: "busy"}]) == "busy"
    end

    test "any online beats everything else" do
      metas = [%{status: "away"}, %{status: "online"}, %{status: "busy"}]
      assert PresenceHelpers.current_status(metas) == "online"
    end

    test "away beats busy" do
      metas = [%{status: "busy"}, %{status: "away"}]
      assert PresenceHelpers.current_status(metas) == "away"
    end

    test "busy beats offline" do
      metas = [%{status: "offline"}, %{status: "busy"}]
      assert PresenceHelpers.current_status(metas) == "busy"
    end

    test "missing :status defaults to 'online'" do
      assert PresenceHelpers.current_status([%{}]) == "online"
    end

    test "unknown status falls through to current acc" do
      metas = [%{status: "ghost"}, %{status: "away"}]
      # away is established first via reduce; ghost has no special case so
      # it keeps the acc → "away"
      assert PresenceHelpers.current_status(metas) == "away"
    end
  end

  describe "latest_online_at/1" do
    test "empty list returns 0" do
      assert PresenceHelpers.latest_online_at([]) == 0
    end

    test "returns the max online_at" do
      metas = [%{online_at: 100}, %{online_at: 500}, %{online_at: 250}]
      assert PresenceHelpers.latest_online_at(metas) == 500
    end

    test "missing key defaults to 0" do
      assert PresenceHelpers.latest_online_at([%{}, %{}]) == 0
    end
  end

  describe "latest_typing_start/1" do
    test "empty list returns 0" do
      assert PresenceHelpers.latest_typing_start([]) == 0
    end

    test "returns the max started_at" do
      metas = [%{started_at: 10}, %{started_at: 99}]
      assert PresenceHelpers.latest_typing_start(metas) == 99
    end
  end

  describe "device_info/1" do
    test "default unknowns" do
      assert PresenceHelpers.device_info(%{}) == %{
               platform: "unknown",
               version: "unknown"
             }
    end

    test "surfaces provided platform/version" do
      assert PresenceHelpers.device_info(%{platform: "ios", version: "17.4"}) == %{
               platform: "ios",
               version: "17.4"
             }
    end
  end

  describe "enrich_metas/2" do
    test "annotates each meta with :user_id" do
      [m1, m2] =
        PresenceHelpers.enrich_metas(
          [%{status: "online"}, %{status: "away"}],
          "u-1"
        )

      assert m1.user_id == "u-1"
      assert m2.user_id == "u-1"
    end

    test "adds device_info if missing" do
      [meta] = PresenceHelpers.enrich_metas([%{status: "online"}], "u-1")
      assert meta.device_info == %{platform: "unknown", version: "unknown"}
    end

    test "preserves existing device_info" do
      provided = %{platform: "android", version: "14"}

      [meta] =
        PresenceHelpers.enrich_metas(
          [%{status: "online", device_info: provided}],
          "u-1"
        )

      assert meta.device_info == provided
    end
  end
end
