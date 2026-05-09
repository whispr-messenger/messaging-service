defmodule WhisprMessaging.Workers.CallsSubscriberTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Workers.CallsSubscriber

  # Les tests handle_participant_left necessitent la DB ; ils sont dans
  # un module separe pour ne pas casser l'isolation async du module principal.

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
end

# WHISPR-1429 : tests du guard handle_participant_left avec acces DB.
defmodule WhisprMessaging.Workers.CallsSubscriber.ParticipantLeftTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Workers.CallsSubscriber

  describe "handle_participant_left/1 (WHISPR-1429)" do
    test "retourne :ok sans crash quand la conversation n'existe pas" do
      fake_conv_id = Ecto.UUID.generate()

      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{fake_conv_id}"
      )

      payload = %{
        "call_id" => Ecto.UUID.generate(),
        "conversation_id" => fake_conv_id,
        "user_id" => Ecto.UUID.generate(),
        "left_at" => "2026-05-09T10:00:00Z"
      }

      assert :ok = CallsSubscriber.handle_participant_left(payload)

      # aucun broadcast ne doit etre emis
      refute_receive %Phoenix.Socket.Broadcast{event: "participant_left"}, 100
    end

    test "retourne :ok sans DB write quand la conversation est inactive" do
      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Test Ended"},
          is_active: true
        })

      # desactiver la conversation (simule ended/deleted)
      Conversations.deactivate_conversation(conv)

      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conv.id}"
      )

      payload = %{
        "call_id" => Ecto.UUID.generate(),
        "conversation_id" => conv.id,
        "user_id" => Ecto.UUID.generate(),
        "left_at" => "2026-05-09T10:00:00Z"
      }

      assert :ok = CallsSubscriber.handle_participant_left(payload)

      # aucun broadcast ne doit etre emis sur une conv inactive
      refute_receive %Phoenix.Socket.Broadcast{event: "participant_left"}, 100
    end

    test "broadcast participant_left sur conv active" do
      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Active Group"},
          is_active: true
        })

      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conv.id}"
      )

      user_id = Ecto.UUID.generate()
      call_id = Ecto.UUID.generate()

      payload = %{
        "call_id" => call_id,
        "conversation_id" => conv.id,
        "user_id" => user_id,
        "left_at" => "2026-05-09T10:00:00Z"
      }

      assert :ok = CallsSubscriber.handle_participant_left(payload)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "participant_left",
                       payload: data
                     },
                     500

      assert data["conversation_id"] == conv.id
      assert data["user_id"] == user_id
      assert data["call_id"] == call_id
    end
  end
end
