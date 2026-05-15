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

  describe "start_link/1 and lifecycle" do
    test "starts a GenServer process" do
      {:ok, pid} = ModerationSubscriber.start_link([])
      assert Process.alive?(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
    end
  end

  describe "handle_info/2 (via send/2)" do
    setup do
      {:ok, pid} = ModerationSubscriber.start_link([])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000) end)
      %{pid: pid}
    end

    test ":subscribed events are silently acknowledged", %{pid: pid} do
      send(
        pid,
        {:redix_pubsub, :ignored, make_ref(), :subscribed,
         %{channel: "whispr:moderation:blocked_image_approved"}}
      )

      # Process should still be alive after handling the message
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "message events trigger a background task", %{pid: pid} do
      user_id = "test-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user_id}")

      payload =
        Jason.encode!(%{
          "appealId" => "appeal-msg",
          "userId" => user_id
        })

      send(
        pid,
        {:redix_pubsub, :ignored, make_ref(), :message,
         %{channel: "whispr:moderation:blocked_image_approved", payload: payload}}
      )

      assert_receive %Phoenix.Socket.Broadcast{event: "blocked_image_decision"}, 1_000
    end

    test "ignores unknown messages", %{pid: pid} do
      send(pid, :something_random)
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "invalid JSON payload is logged but does not crash the process", %{pid: pid} do
      send(
        pid,
        {:redix_pubsub, :ignored, make_ref(), :message,
         %{channel: "whispr:moderation:blocked_image_approved", payload: "{not json}"}}
      )

      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end
end
