defmodule WhisprMessaging.Events.MessagingEventsTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.Events.MessagingEvents

  setup do
    test_pid = self()

    publisher = fn channel, payload ->
      send(test_pid, {:redis_publish, channel, payload})
      {:ok, 1}
    end

    previous = Application.get_env(:whispr_messaging, :messaging_events_publisher)
    Application.put_env(:whispr_messaging, :messaging_events_publisher, publisher)

    on_exit(fn ->
      if previous do
        Application.put_env(:whispr_messaging, :messaging_events_publisher, previous)
      else
        Application.delete_env(:whispr_messaging, :messaging_events_publisher)
      end
    end)

    :ok
  end

  describe "publish_new_message/3" do
    test "publishes on the new_message channel with recipients excluding the sender" do
      message = %{
        id: "msg-1",
        conversation_id: "conv-1",
        sender_id: "user-sender"
      }

      members = [
        %{user_id: "user-sender"},
        %{user_id: "user-a"},
        %{user_id: "user-b"}
      ]

      assert :ok = MessagingEvents.publish_new_message(message, members)

      assert_receive {:redis_publish, "whispr:messaging:new_message", json}
      payload = Jason.decode!(json)

      assert payload["conversation_id"] == "conv-1"
      assert payload["message_id"] == "msg-1"
      assert payload["sender_id"] == "user-sender"
      assert payload["count"] == 1
      assert Enum.sort(payload["target_user_ids"]) == ["user-a", "user-b"]
    end

    test "deduplicates recipients" do
      message = %{id: "m", conversation_id: "c", sender_id: "s"}

      members = [
        %{user_id: "a"},
        %{user_id: "a"},
        %{user_id: "b"}
      ]

      assert :ok = MessagingEvents.publish_new_message(message, members)

      assert_receive {:redis_publish, _channel, json}
      payload = Jason.decode!(json)
      assert Enum.sort(payload["target_user_ids"]) == ["a", "b"]
    end

    test "does not publish when the only member is the sender" do
      message = %{id: "m", conversation_id: "c", sender_id: "s"}
      members = [%{user_id: "s"}]

      assert :ok = MessagingEvents.publish_new_message(message, members)
      refute_receive {:redis_publish, _channel, _json}, 50
    end

    test "honours an explicit count override" do
      message = %{id: "m", conversation_id: "c", sender_id: "s"}
      members = [%{user_id: "s"}, %{user_id: "a"}]

      assert :ok = MessagingEvents.publish_new_message(message, members, count: 3)
      assert_receive {:redis_publish, _channel, json}
      assert Jason.decode!(json)["count"] == 3
    end
  end

  describe "publish_message_read/4" do
    test "publishes on the message_read channel with the reader's id" do
      assert :ok =
               MessagingEvents.publish_message_read("conv-1", "user-a", "msg-1")

      assert_receive {:redis_publish, "whispr:messaging:message_read", json}
      payload = Jason.decode!(json)

      assert payload["conversation_id"] == "conv-1"
      assert payload["user_id"] == "user-a"
      assert payload["message_id"] == "msg-1"
      assert payload["count"] == 1
    end

    test "tolerates a nil message_id for whole-conversation reads" do
      assert :ok = MessagingEvents.publish_message_read("conv-1", "user-a", nil, count: 5)

      assert_receive {:redis_publish, "whispr:messaging:message_read", json}
      payload = Jason.decode!(json)

      assert payload["message_id"] == nil
      assert payload["count"] == 5
    end
  end
end
