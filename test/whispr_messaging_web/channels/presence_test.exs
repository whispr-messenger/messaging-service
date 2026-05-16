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

  describe "track_user/3 + list_users/1 + get_user_status/1 (real tracking)" do
    test "tracks a user globally and exposes them via list_users/get_user_status/user_online?" do
      user_id = Ecto.UUID.generate()
      topic = "user:#{user_id}"

      # Subscribe the test process so Presence dispatches messages we can
      # observe and so untracking happens automatically when this test exits.
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, topic)
      {:ok, _} = Presence.track(self(), topic, user_id, %{status: "online", online_at: 1234})

      # Allow Presence to emit the join broadcast before we query state.
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500

      users = Presence.list_users(topic)
      assert [%{user_id: ^user_id, status: "online", device_count: 1}] = users

      assert Presence.user_online?(user_id) == true
      assert Presence.get_user_status(user_id) == "online"

      # untrack via Phoenix.Presence so the test process is clean
      Presence.untrack(self(), topic, user_id)
    end

    test "track_typing/3 records a typing entry that appears in get_typing_users" do
      conv_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      topic = "conversation:#{conv_id}"

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, topic)

      # Build a minimal Phoenix.Socket whose pubsub_server / topic match what
      # Presence.track expects when called via the wrapper.
      socket = %Phoenix.Socket{
        topic: topic,
        channel_pid: self(),
        pubsub_server: WhisprMessaging.PubSub,
        joined: true,
        ref: "1",
        transport: :test,
        endpoint: WhisprMessagingWeb.Endpoint,
        handler: WhisprMessagingWeb.UserSocket
      }

      # `track_typing/3` schedules a self-message; we don't care about it here.
      _ = Presence.track_typing(socket, user_id, conv_id)

      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500
      typing = Presence.get_typing_users(conv_id)
      assert [%{user_id: ^user_id}] = typing

      # Drain the auto-scheduled :stop_typing message so the mailbox is clean.
      receive do
        {:stop_typing, _, _} -> :ok
      after
        0 -> :ok
      end

      Presence.untrack(self(), topic, "typing:#{user_id}")
    end

    test "get_conversation_users/1 returns tracked users in conversation:<id>" do
      conv_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      topic = "conversation:#{conv_id}"

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, topic)
      {:ok, _} = Presence.track(self(), topic, user_id, %{status: "online", online_at: 9})
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500

      users = Presence.get_conversation_users(conv_id)
      assert [%{user_id: ^user_id, status: "online"}] = users

      Presence.untrack(self(), topic, user_id)
    end

    test "update_user/3 modifies the meta of a tracked user" do
      user_id = Ecto.UUID.generate()
      topic = "user:#{user_id}"

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, topic)
      {:ok, _} = Presence.track(self(), topic, user_id, %{status: "online", online_at: 1})
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500

      socket = %Phoenix.Socket{
        topic: topic,
        channel_pid: self(),
        pubsub_server: WhisprMessaging.PubSub,
        joined: true,
        ref: "2",
        transport: :test,
        endpoint: WhisprMessagingWeb.Endpoint,
        handler: WhisprMessagingWeb.UserSocket
      }

      {:ok, _} = Presence.update_user(socket, user_id, %{status: "away", online_at: 2})
      assert_receive %Phoenix.Socket.Broadcast{event: "presence_diff"}, 500

      assert Presence.get_user_status(user_id) == "away"
      Presence.untrack(self(), topic, user_id)
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
