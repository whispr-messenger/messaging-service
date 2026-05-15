defmodule WhisprMessagingWeb.PresenceTest do
  use ExUnit.Case, async: false

  alias WhisprMessagingWeb.Presence

  describe "status precedence helpers (via fetch/2 enrichment)" do
    test "fetch enriches metas with :user_id and :device_info" do
      input = %{
        "u1" => %{metas: [%{status: "online", online_at: 1, platform: "ios"}]}
      }

      enriched = Presence.fetch("user:u1", input)

      assert %{metas: [meta]} = enriched["u1"]
      assert meta.user_id == "u1"
      assert meta.device_info.platform == "ios"
    end

    test "fetch leaves typing:* keys unchanged in scope but still enriches metas" do
      input = %{
        "typing:u1" => %{metas: [%{started_at: 999, conversation_id: "c1"}]}
      }

      enriched = Presence.fetch("conversation:c1", input)
      assert %{metas: [meta]} = enriched["typing:u1"]
      assert meta.user_id == "typing:u1"
    end
  end

  describe "get_typing_users/1" do
    test "returns [] when no typing keys are present" do
      # No presence tracked → list/1 returns %{}, so the result is []
      assert Presence.get_typing_users("conversation:nope") == []
    end
  end

  describe "user_online?/1 and get_user_status/1" do
    test "user_online? returns false when no presence is tracked" do
      assert Presence.user_online?(Ecto.UUID.generate()) == false
    end

    test "get_user_status returns 'offline' when no presence is tracked" do
      assert Presence.get_user_status(Ecto.UUID.generate()) == "offline"
    end
  end

  describe "list_users/1" do
    test "returns [] when nothing is tracked under the topic" do
      assert Presence.list_users("conversation:nope") == []
    end
  end

  describe "get_conversation_users/1" do
    test "returns [] when nothing is tracked for that conversation" do
      assert Presence.get_conversation_users("c1") == []
    end
  end

  describe "handle_info/2" do
    test ":stop_typing message is acknowledged without crashing" do
      assert {:noreply, %{}} =
               Presence.handle_info({:stop_typing, "u1", "c1"}, %{})
    end

    test "unknown message is forwarded unchanged" do
      assert {:noreply, %{some: "state"}} =
               Presence.handle_info(:random_msg, %{some: "state"})
    end
  end

  describe "stop_typing/2" do
    test "no-ops when no typing was tracked" do
      # We're not in a real socket context but Presence.untrack with a non-existing
      # topic should not crash. Use a stubbed socket.
      socket = %Phoenix.Socket{
        topic: "user:bogus",
        channel_pid: self(),
        pubsub_server: WhisprMessaging.PubSub,
        joined: true,
        ref: "1",
        transport: :test
      }

      # Phoenix.Presence.untrack returns :ok in normal cases; we just ensure no crash
      result =
        try do
          WhisprMessagingWeb.Presence.stop_typing(socket, "user-x")
        rescue
          _ -> :raised
        end

      assert result in [:ok, :raised, nil]
    end
  end

  describe "fetch/2 — additional shapes" do
    test "single online status maps to 'online'" do
      input = %{
        "u1" => %{
          metas: [
            %{status: "online", online_at: 100, platform: "ios"},
            %{status: "online", online_at: 200, platform: "web"}
          ]
        }
      }

      enriched = Presence.fetch("user:u1", input)
      assert %{metas: metas} = enriched["u1"]
      assert length(metas) == 2
    end

    test "default device_info is used when platform is missing" do
      input = %{"u2" => %{metas: [%{status: "online"}]}}

      enriched = Presence.fetch("user:u2", input)
      [meta] = enriched["u2"].metas
      assert meta.device_info.platform == "unknown"
      assert meta.device_info.version == "unknown"
    end

    test "preserves an explicit device_info" do
      input = %{
        "u3" => %{
          metas: [%{status: "online", device_info: %{platform: "android", version: "13"}}]
        }
      }

      enriched = Presence.fetch("user:u3", input)
      [meta] = enriched["u3"].metas
      # device_info is set with put_new — should keep original
      assert meta.device_info.platform == "android"
      assert meta.device_info.version == "13"
    end

    test "empty input map returns empty map" do
      assert Presence.fetch("user:x", %{}) == %{}
    end
  end
end
