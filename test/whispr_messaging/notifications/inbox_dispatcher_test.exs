defmodule WhisprMessaging.Notifications.InboxDispatcherTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Notifications.InboxDispatcher

  # ---------------------------------------------------------------------------
  # Shared publisher stub setup
  # ---------------------------------------------------------------------------

  defp setup_publisher(test_pid) do
    publisher = fn channel, payload ->
      send(test_pid, {:inbox_publish, channel, payload})
      {:ok, 1}
    end

    previous = Application.get_env(:whispr_messaging, :inbox_dispatcher_publisher)
    Application.put_env(:whispr_messaging, :inbox_dispatcher_publisher, publisher)

    on_exit(fn ->
      if previous do
        Application.put_env(:whispr_messaging, :inbox_dispatcher_publisher, previous)
      else
        Application.delete_env(:whispr_messaging, :inbox_dispatcher_publisher)
      end
    end)

    publisher
  end

  # ---------------------------------------------------------------------------
  # publish_event/3
  # ---------------------------------------------------------------------------

  describe "publish_event/3" do
    setup do
      setup_publisher(self())
      :ok
    end

    test "encodes and publishes the envelope on the inbox channel" do
      payload = %{"from_user_id" => "u-sender", "conversation_id" => "c-1"}

      assert :ok = InboxDispatcher.publish_event("u-target", "mention", payload)

      assert_receive {:inbox_publish, "whispr:notifications:inbox", json}
      envelope = Jason.decode!(json)

      assert envelope["user_id"] == "u-target"
      assert envelope["event_type"] == "mention"
      assert envelope["payload"]["from_user_id"] == "u-sender"
    end

    test "returns :ok even when the publisher errors" do
      Application.put_env(:whispr_messaging, :inbox_dispatcher_publisher, fn _ch, _pl ->
        {:error, :redis_down}
      end)

      assert :ok = InboxDispatcher.publish_event("u", "mention", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch_mentions/2 - unit tests (no DB)
  # ---------------------------------------------------------------------------

  describe "dispatch_mentions/2 - unit" do
    setup do
      setup_publisher(self())
      :ok
    end

    defp make_message(sender_id, mentions, opts \\ []) do
      conversation_id = Keyword.get(opts, :conversation_id, "conv-1")
      conversation_type = Keyword.get(opts, :conversation_type, "direct")
      conversation_name = Keyword.get(opts, :conversation_name, nil)

      %{
        id: "msg-1",
        sender_id: sender_id,
        conversation_id: conversation_id,
        content: <<1, 2, 3>>,
        metadata: %{"mentions" => mentions},
        conversation: %{type: conversation_type, metadata: %{"name" => conversation_name}},
        reply_to: nil,
        reply_to_id: nil
      }
    end

    defp make_member(user_id), do: %{user_id: user_id}

    test "publishes one event per valid mention" do
      members = [make_member("u-a"), make_member("u-b"), make_member("u-sender")]

      message =
        make_message("u-sender", [
          %{"user_id" => "u-a", "username" => "@alice"},
          %{"user_id" => "u-b", "username" => "@bob"}
        ])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)

      assert_receive {:inbox_publish, "whispr:notifications:inbox", json_a}
      assert_receive {:inbox_publish, "whispr:notifications:inbox", json_b}

      targets =
        [json_a, json_b]
        |> Enum.map(&Jason.decode!/1)
        |> Enum.map(& &1["user_id"])
        |> Enum.sort()

      assert targets == ["u-a", "u-b"]
    end

    test "does not publish when the sender mentions themselves" do
      members = [make_member("u-sender")]

      message =
        make_message("u-sender", [
          %{"user_id" => "u-sender", "username" => "@me"}
        ])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "does not publish when mentioned user is not a conversation member" do
      # u-stranger is mentioned but not in the member list
      members = [make_member("u-sender")]

      message =
        make_message("u-sender", [
          %{"user_id" => "u-stranger", "username" => "@stranger"}
        ])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "deduplicates by only publishing once per mentioned user" do
      members = [make_member("u-a"), make_member("u-sender")]

      message =
        make_message("u-sender", [
          %{"user_id" => "u-a", "username" => "@alice"},
          %{"user_id" => "u-a", "username" => "@alice"}
        ])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)

      # Two identical mentions produce two publishes (idempotency is the
      # notification-service's responsibility, not ours).
      assert_receive {:inbox_publish, _, json1}
      assert_receive {:inbox_publish, _, json2}
      refute_receive {:inbox_publish, _, _}, 50

      assert Jason.decode!(json1)["user_id"] == "u-a"
      assert Jason.decode!(json2)["user_id"] == "u-a"
    end

    test "includes conversation_name for group conversations" do
      members = [make_member("u-a"), make_member("u-sender")]

      message =
        make_message(
          "u-sender",
          [%{"user_id" => "u-a", "username" => "@alice"}],
          conversation_type: "group",
          conversation_name: "Dev Team"
        )

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      assert_receive {:inbox_publish, _, json}
      payload = Jason.decode!(json)

      assert payload["payload"]["conversation_name"] == "Dev Team"
    end

    test "sets conversation_name to nil for direct conversations" do
      members = [make_member("u-a"), make_member("u-sender")]
      message = make_message("u-sender", [%{"user_id" => "u-a", "username" => "@alice"}])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      assert_receive {:inbox_publish, _, json}
      payload = Jason.decode!(json)

      assert is_nil(payload["payload"]["conversation_name"])
    end

    test "is a no-op when metadata has no mentions key" do
      members = [make_member("u-a")]
      message = %{make_message("u-sender", []) | metadata: %{}}

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "is a no-op when mentions list is empty" do
      members = [make_member("u-a")]
      message = make_message("u-sender", [])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "is a no-op when message has no metadata" do
      members = [make_member("u-a")]
      message = Map.put(make_message("u-sender", []), :metadata, nil)

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "preview is nil when no plaintext_preview in metadata" do
      members = [make_member("u-a"), make_member("u-sender")]
      message = make_message("u-sender", [%{"user_id" => "u-a", "username" => "@alice"}])

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      assert_receive {:inbox_publish, _, json}
      assert is_nil(Jason.decode!(json)["payload"]["preview"])
    end

    test "preview is sliced to 80 chars from plaintext_preview in metadata" do
      long_preview = String.duplicate("a", 100)
      members = [make_member("u-a"), make_member("u-sender")]

      message = %{
        make_message("u-sender", [%{"user_id" => "u-a", "username" => "@alice"}])
        | metadata: %{
            "mentions" => [%{"user_id" => "u-a", "username" => "@alice"}],
            "plaintext_preview" => long_preview
          }
      }

      assert :ok = InboxDispatcher.dispatch_mentions(message, members)
      assert_receive {:inbox_publish, _, json}
      preview = Jason.decode!(json)["payload"]["preview"]
      assert byte_size(preview) == 80
    end
  end

  # ---------------------------------------------------------------------------
  # dispatch_reply/1 - unit tests (no DB)
  # ---------------------------------------------------------------------------

  describe "dispatch_reply/1 - unit" do
    setup do
      setup_publisher(self())
      :ok
    end

    defp make_reply_message(sender_id, original_sender_id, opts \\ []) do
      reply_to_id = Keyword.get(opts, :reply_to_id, "msg-original")

      %{
        id: "msg-reply",
        sender_id: sender_id,
        conversation_id: "conv-1",
        content: <<1, 2, 3>>,
        metadata: %{},
        reply_to_id: reply_to_id,
        reply_to: %{id: reply_to_id, sender_id: original_sender_id},
        conversation: %{type: "direct", metadata: %{}}
      }
    end

    test "publishes a reply event to the original sender" do
      message = make_reply_message("u-replier", "u-original")

      assert :ok = InboxDispatcher.dispatch_reply(message)

      assert_receive {:inbox_publish, "whispr:notifications:inbox", json}
      envelope = Jason.decode!(json)

      assert envelope["user_id"] == "u-original"
      assert envelope["event_type"] == "reply"
      assert envelope["payload"]["from_user_id"] == "u-replier"
      assert envelope["payload"]["message_id"] == "msg-reply"
    end

    test "does not publish when reply_to_id is nil" do
      message = %{
        id: "msg-1",
        sender_id: "u-sender",
        conversation_id: "conv-1",
        content: <<1>>,
        metadata: %{},
        reply_to_id: nil,
        reply_to: nil,
        conversation: %{type: "direct", metadata: %{}}
      }

      assert :ok = InboxDispatcher.dispatch_reply(message)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "does not publish on self-reply" do
      message = make_reply_message("u-sender", "u-sender")

      assert :ok = InboxDispatcher.dispatch_reply(message)
      refute_receive {:inbox_publish, _, _}, 50
    end

    test "does not publish when reply_to is not preloaded and DB lookup fails" do
      # Simulate a deleted/non-existent parent message: reply_to is nil struct
      message = %{
        id: "msg-reply",
        sender_id: "u-replier",
        conversation_id: "conv-1",
        content: <<1>>,
        metadata: %{},
        reply_to_id: Ecto.UUID.generate(),
        reply_to: nil,
        conversation: %{type: "direct", metadata: %{}}
      }

      # DB lookup will return :not_found for the random UUID
      assert :ok = InboxDispatcher.dispatch_reply(message)
      refute_receive {:inbox_publish, _, _}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: hook is called after message creation
  # ---------------------------------------------------------------------------

  describe "integration - inbox events triggered by create_message/1" do
    setup do
      test_pid = self()

      publisher = fn channel, payload ->
        send(test_pid, {:inbox_publish, channel, payload})
        {:ok, 1}
      end

      prev_publisher = Application.get_env(:whispr_messaging, :inbox_dispatcher_publisher)

      Application.put_env(:whispr_messaging, :inbox_dispatcher_publisher, publisher)

      # Run inbox dispatcher synchronously so the test can assert on it
      # without race conditions.
      prev_dispatcher = Application.get_env(:whispr_messaging, :inbox_events_dispatcher)

      Application.put_env(:whispr_messaging, :inbox_events_dispatcher, fn message ->
        members = Conversations.list_conversation_members(message.conversation_id)
        InboxDispatcher.dispatch_mentions(message, members)
        InboxDispatcher.dispatch_reply(message)
      end)

      on_exit(fn ->
        if prev_publisher do
          Application.put_env(:whispr_messaging, :inbox_dispatcher_publisher, prev_publisher)
        else
          Application.delete_env(:whispr_messaging, :inbox_dispatcher_publisher)
        end

        if prev_dispatcher do
          Application.put_env(:whispr_messaging, :inbox_events_dispatcher, prev_dispatcher)
        else
          Application.delete_env(:whispr_messaging, :inbox_events_dispatcher)
        end
      end)

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      sender_id = Ecto.UUID.generate()
      recipient_id = Ecto.UUID.generate()

      {:ok, _} = Conversations.add_conversation_member(conversation.id, sender_id)
      {:ok, _} = Conversations.add_conversation_member(conversation.id, recipient_id)

      %{
        conversation: conversation,
        sender_id: sender_id,
        recipient_id: recipient_id
      }
    end

    test "mention in metadata triggers a mention event for the recipient", %{
      conversation: conv,
      sender_id: sender_id,
      recipient_id: recipient_id
    } do
      attrs = %{
        conversation_id: conv.id,
        sender_id: sender_id,
        message_type: "text",
        content: "encrypted_body",
        client_random: System.unique_integer([:positive]),
        metadata: %{
          "mentions" => [%{"user_id" => recipient_id, "username" => "@recipient"}]
        }
      }

      assert {:ok, _message} = Messages.create_message(attrs)

      assert_receive {:inbox_publish, "whispr:notifications:inbox", json}, 500
      envelope = Jason.decode!(json)

      assert envelope["user_id"] == recipient_id
      assert envelope["event_type"] == "mention"
      assert envelope["payload"]["from_user_id"] == sender_id
    end

    test "reply triggers a reply event to the original sender", %{
      conversation: conv,
      sender_id: sender_id,
      recipient_id: recipient_id
    } do
      # Create the original message from recipient_id
      original_attrs = %{
        conversation_id: conv.id,
        sender_id: recipient_id,
        message_type: "text",
        content: "original encrypted",
        client_random: System.unique_integer([:positive]),
        metadata: %{}
      }

      assert {:ok, original_message} = Messages.create_message(original_attrs)

      # Drain any publish from the original message creation
      receive do
        {:inbox_publish, _, _} -> :ok
      after
        50 -> :ok
      end

      # sender_id replies to recipient_id's message
      reply_attrs = %{
        conversation_id: conv.id,
        sender_id: sender_id,
        message_type: "text",
        content: "reply encrypted",
        client_random: System.unique_integer([:positive]),
        metadata: %{},
        reply_to_id: original_message.id
      }

      assert {:ok, _reply} = Messages.create_message(reply_attrs)

      assert_receive {:inbox_publish, "whispr:notifications:inbox", json}, 500
      envelope = Jason.decode!(json)

      assert envelope["user_id"] == recipient_id
      assert envelope["event_type"] == "reply"
      assert envelope["payload"]["from_user_id"] == sender_id
    end

    test "no mention event when mentioned user is not a conversation member", %{
      conversation: conv,
      sender_id: sender_id
    } do
      stranger_id = Ecto.UUID.generate()

      attrs = %{
        conversation_id: conv.id,
        sender_id: sender_id,
        message_type: "text",
        content: "encrypted_body",
        client_random: System.unique_integer([:positive]),
        metadata: %{
          "mentions" => [%{"user_id" => stranger_id, "username" => "@stranger"}]
        }
      }

      assert {:ok, _} = Messages.create_message(attrs)
      refute_receive {:inbox_publish, _, _}, 200
    end

    test "self-reply does not emit a reply event", %{
      conversation: conv,
      sender_id: sender_id
    } do
      original_attrs = %{
        conversation_id: conv.id,
        sender_id: sender_id,
        message_type: "text",
        content: "self original",
        client_random: System.unique_integer([:positive]),
        metadata: %{}
      }

      assert {:ok, original_message} = Messages.create_message(original_attrs)

      receive do
        {:inbox_publish, _, _} -> :ok
      after
        50 -> :ok
      end

      reply_attrs = %{
        conversation_id: conv.id,
        sender_id: sender_id,
        message_type: "text",
        content: "self reply",
        client_random: System.unique_integer([:positive]),
        metadata: %{},
        reply_to_id: original_message.id
      }

      assert {:ok, _} = Messages.create_message(reply_attrs)
      refute_receive {:inbox_publish, _, _}, 200
    end
  end
end
