defmodule WhisprMessaging.Workers.ModerationSubscriberTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Workers.ModerationSubscriber

  describe "broadcast_decision/2" do
    test "broadcasts approved decision on the user topic" do
      user_id = "user-abc"
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user_id}")

      payload = %{
        "appealId" => "appeal-100",
        "userId" => user_id,
        "conversationId" => "conv-1",
        "messageTempId" => "temp-1",
        "reviewerNotes" => nil
      }

      assert :ok = ModerationSubscriber.broadcast_decision("approved", payload)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "blocked_image_decision",
        payload: broadcast_payload
      }

      assert topic == "user:#{user_id}"
      assert broadcast_payload["appealId"] == "appeal-100"
      assert broadcast_payload["decision"] == "approved"
      assert broadcast_payload["messageTempId"] == "temp-1"
      assert broadcast_payload["conversationId"] == "conv-1"
      refute Map.has_key?(broadcast_payload, "reviewerNotes")
    end

    test "broadcasts rejected decision with reviewer notes" do
      user_id = "user-def"
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user_id}")

      payload = %{
        "appealId" => "appeal-101",
        "userId" => user_id,
        "messageTempId" => "temp-2",
        "reviewerNotes" => "Policy violation"
      }

      assert :ok = ModerationSubscriber.broadcast_decision("rejected", payload)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "blocked_image_decision",
        payload: broadcast_payload
      }

      assert topic == "user:#{user_id}"
      assert broadcast_payload["decision"] == "rejected"
      assert broadcast_payload["messageTempId"] == "temp-2"
      assert broadcast_payload["reviewerNotes"] == "Policy violation"
      refute Map.has_key?(broadcast_payload, "conversationId")
    end

    test "skips broadcast when userId is nil or empty" do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:")

      assert :ok =
               ModerationSubscriber.broadcast_decision("approved", %{
                 "appealId" => "appeal-x",
                 "userId" => nil
               })

      assert :ok =
               ModerationSubscriber.broadcast_decision("rejected", %{
                 "appealId" => "appeal-y",
                 "userId" => ""
               })

      refute_receive %Phoenix.Socket.Broadcast{event: "blocked_image_decision"}, 50
    end
  end
end
