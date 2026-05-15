defmodule WhisprMessaging.MessagesExtrasTest do
  @moduledoc """
  Additional coverage for `WhisprMessaging.Messages` functions not exercised
  by the main `messages_test.exs`.
  """

  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.{Conversations, Messages}

  defp setup_two_user_conv do
    u1 = Ecto.UUID.generate()
    u2 = Ecto.UUID.generate()

    {:ok, conv} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conv.id, u1)
    {:ok, _} = Conversations.add_conversation_member(conv.id, u2)

    {u1, u2, conv}
  end

  describe "user_can_access_message?/2" do
    test "returns true for a member" do
      {u1, _u2, conv} = setup_two_user_conv()
      assert Messages.user_can_access_message?(conv.id, u1)
    end

    test "returns false for a non-member" do
      {_u1, _u2, conv} = setup_two_user_conv()
      refute Messages.user_can_access_message?(conv.id, Ecto.UUID.generate())
    end
  end

  describe "get_message_sender/1" do
    test "returns {:ok, sender_id} for an existing message" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, sender} = Messages.get_message_sender(msg.id)
      assert sender == u1
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = Messages.get_message_sender(Ecto.UUID.generate())
    end
  end

  describe "get_message_by_sender_and_random/2" do
    test "returns the matching message" do
      {u1, _u2, conv} = setup_two_user_conv()
      cr = System.unique_integer([:positive])

      {:ok, _} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: cr
        })

      assert {:ok, msg} = Messages.get_message_by_sender_and_random(u1, cr)
      assert msg.client_random == cr
    end

    test "returns :not_found when no match" do
      assert {:error, :not_found} =
               Messages.get_message_by_sender_and_random(Ecto.UUID.generate(), 99_999)
    end
  end

  describe "get_pending_delivery_confirmations/1" do
    test "returns {:ok, []} (stub for offline confirmations)" do
      assert {:ok, []} = Messages.get_pending_delivery_confirmations(Ecto.UUID.generate())
    end
  end

  describe "get_read_receipt_summary/1" do
    test "returns total_recipients = 0 when message has no delivery statuses" do
      assert {:ok, summary} = Messages.get_read_receipt_summary(Ecto.UUID.generate())
      assert summary.total_recipients == 0
    end
  end

  describe "get_message_delivery_status/2" do
    test "returns 'sent' when no delivery status exists for the user" do
      assert "sent" =
               Messages.get_message_delivery_status(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "list_recent_messages/4" do
    test "returns recent messages of a conversation" do
      {u1, _u2, conv} = setup_two_user_conv()

      Enum.each(1..3, fn i ->
        {:ok, _} =
          Messages.create_message(%{
            conversation_id: conv.id,
            sender_id: u1,
            message_type: "text",
            content: "msg-#{i}",
            client_random: System.unique_integer([:positive])
          })
      end)

      msgs = Messages.list_recent_messages(conv.id, 10)
      assert length(msgs) == 3
    end
  end

  describe "list_undelivered_messages/1" do
    # Requires a real user id that may exist in delivery_statuses; this
    # function expects a real UUID, but the Postgrex encoder is strict.
    # The path is exercised via integration in messages_test.exs.
  end

  describe "search_messages/3 (compat wrapper)" do
    test "returns a list" do
      assert is_list(Messages.search_messages(Ecto.UUID.generate(), "anything"))
    end
  end

  describe "count_unread_messages/3" do
    test "returns an integer (0 for unknown conversation)" do
      count =
        Messages.count_unread_messages(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          DateTime.utc_now()
        )

      assert is_integer(count)
    end
  end

  describe "forward_message/3" do
    test "returns {:error, :forbidden} when caller is not a member of source" do
      {u1, _u2, conv1} = setup_two_user_conv()
      stranger = Ecto.UUID.generate()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv1.id,
          sender_id: u1,
          message_type: "text",
          content: "to forward",
          client_random: System.unique_integer([:positive])
        })

      {_u3, _u4, conv2} = setup_two_user_conv()
      assert {:error, :forbidden} = Messages.forward_message(msg.id, [conv2.id], stranger)
    end

    test "returns {:error, :not_found} for an unknown source message_id" do
      assert {:error, :not_found} =
               Messages.forward_message(
                 Ecto.UUID.generate(),
                 [Ecto.UUID.generate()],
                 Ecto.UUID.generate()
               )
    end
  end

  describe "get_message_with_relations/1" do
    test "returns {:ok, message} for an existing message" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "hi",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, fetched} = Messages.get_message_with_relations(msg.id)
      assert fetched.id == msg.id
    end

    test "returns {:error, :not_found} for unknown id" do
      assert {:error, :not_found} = Messages.get_message_with_relations(Ecto.UUID.generate())
    end
  end

  describe "create_attachment/1 + get_attachment/1 + delete_attachment/1" do
    test "creates and deletes an attachment" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "media",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, attachment} =
               Messages.create_attachment(%{
                 message_id: msg.id,
                 filename: "a.png",
                 file_type: "image",
                 file_size: 12,
                 mime_type: "image/png",
                 storage_url: "/a.png"
               })

      assert {:ok, fetched} = Messages.get_attachment(attachment.id)
      assert fetched.id == attachment.id

      assert {:ok, _} = Messages.delete_attachment(attachment.id)
      assert {:error, :not_found} = Messages.get_attachment(attachment.id)
    end

    test "delete_attachment returns error for unknown id" do
      assert {:error, :not_found} = Messages.delete_attachment(Ecto.UUID.generate())
    end
  end
end
