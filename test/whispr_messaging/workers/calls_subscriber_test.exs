defmodule WhisprMessaging.Workers.CallsSubscriberTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Workers.CallsSubscriber

  describe "broadcast_incoming_call/1" do
    test "broadcasts incoming_call to every participant except the initiator" do
      initiator = "user-initiator"
      callee_a = "user-callee-a"
      callee_b = "user-callee-b"

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{callee_a}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{callee_b}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{initiator}")

      payload = %{
        "call_id" => "call-1",
        "initiator_id" => initiator,
        "conversation_id" => "conv-1",
        "type" => "audio",
        "livekit_room" => "call_abc",
        "participant_ids" => [initiator, callee_a, callee_b],
        "started_at" => "2026-04-23T22:00:00Z"
      }

      assert :ok = CallsSubscriber.broadcast_incoming_call(payload)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:" <> ^callee_a,
        event: "incoming_call",
        payload: data_a
      }

      assert data_a["call_id"] == "call-1"
      assert data_a["initiator_id"] == initiator
      assert data_a["conversation_id"] == "conv-1"
      assert data_a["type"] == "audio"
      assert data_a["started_at"] == "2026-04-23T22:00:00Z"

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:" <> ^callee_b,
        event: "incoming_call"
      }

      # The initiator MUST NOT receive their own call notification.
      refute_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> ^initiator,
                       event: "incoming_call"
                     },
                     50
    end

    test "dedupes participant_ids and filters empty / non-string entries" do
      callee = "user-callee"
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{callee}")

      payload = %{
        "call_id" => "call-2",
        "initiator_id" => "user-initiator",
        "participant_ids" => [callee, callee, "", nil, "user-initiator"]
      }

      assert :ok = CallsSubscriber.broadcast_incoming_call(payload)

      # Only one broadcast to callee, nothing else.
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:" <> ^callee,
        event: "incoming_call"
      }

      refute_receive %Phoenix.Socket.Broadcast{event: "incoming_call"}, 50
    end

    test "no-ops when participant_ids is missing or only contains the initiator" do
      initiator = "user-solo"
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{initiator}")

      assert :ok =
               CallsSubscriber.broadcast_incoming_call(%{
                 "call_id" => "call-3",
                 "initiator_id" => initiator
               })

      assert :ok =
               CallsSubscriber.broadcast_incoming_call(%{
                 "call_id" => "call-4",
                 "initiator_id" => initiator,
                 "participant_ids" => [initiator]
               })

      refute_receive %Phoenix.Socket.Broadcast{event: "incoming_call"}, 50
    end
  end

  describe "handle_info/2" do
    test "logs and ignores subscribed events" do
      assert {:noreply, %{}} ==
               CallsSubscriber.handle_info(
                 {:redix_pubsub, :pid, :ref, :subscribed, %{channel: "x"}},
                 %{}
               )
    end

    test "stops the worker on :retry_connect" do
      assert {:stop, :normal, %{pubsub: nil}} ==
               CallsSubscriber.handle_info(:retry_connect, %{pubsub: nil})
    end

    test "ignores unrecognised messages" do
      assert {:noreply, :state} == CallsSubscriber.handle_info(:something_else, :state)
    end
  end
end
