defmodule WhisprMessagingWeb.PresenceTest do
  @moduledoc """
  Tests the Phoenix.Presence wrapper. Focuses on the pure helper functions
  (`fetch/2`, status reduction) and basic predicates that do not require a
  live socket — keeping the suite hermetic.
  """

  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.Presence

  describe "fetch/2" do
    test "enriches each meta with a user_id and device_info" do
      presences = %{
        "u-1" => %{metas: [%{platform: "ios", version: "1.0"}]}
      }

      result = Presence.fetch("user:u-1", presences)

      [meta] = result["u-1"].metas
      assert meta.user_id == "u-1"
      assert meta.device_info.platform == "ios"
      assert meta.device_info.version == "1.0"
    end

    test "returns an empty map when given empty presences" do
      assert %{} == Presence.fetch("user:any", %{})
    end

    test "preserves existing device_info if set" do
      pre = %{"u-1" => %{metas: [%{device_info: %{platform: "web"}}]}}
      result = Presence.fetch("user:u-1", pre)

      [meta] = result["u-1"].metas
      assert meta.device_info.platform == "web"
    end
  end

  describe "user_online?/1" do
    test "returns false when no presence is tracked for the user" do
      refute Presence.user_online?(Ecto.UUID.generate())
    end
  end

  describe "get_user_status/1" do
    test "returns 'offline' when no session is tracked" do
      assert "offline" == Presence.get_user_status(Ecto.UUID.generate())
    end
  end

  describe "get_typing_users/1" do
    test "returns an empty list when no presences are tracked" do
      assert [] == Presence.get_typing_users(Ecto.UUID.generate())
    end
  end

  describe "get_conversation_users/1" do
    test "returns an empty list when no presences are tracked" do
      assert [] == Presence.get_conversation_users(Ecto.UUID.generate())
    end
  end

  describe "handle_info/2" do
    test "ignores stop_typing messages without crashing" do
      assert {:noreply, %{}} ==
               Presence.handle_info({:stop_typing, "u-1", "c-1"}, %{})
    end

    test "ignores unrecognised messages" do
      assert {:noreply, :state} == Presence.handle_info(:something_else, :state)
    end
  end
end
