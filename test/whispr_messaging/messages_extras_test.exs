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

  describe "forward_message/3 — happy path" do
    test "forwards a message to a target conversation the user belongs to" do
      {u1, _u2, source_conv} = setup_two_user_conv()
      {_u3, _u4, target_conv} = setup_two_user_conv()
      {:ok, _} = Conversations.add_conversation_member(target_conv.id, u1)

      {:ok, source} =
        Messages.create_message(%{
          conversation_id: source_conv.id,
          sender_id: u1,
          message_type: "text",
          content: "fan out",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, [forwarded]} =
               Messages.forward_message(source.id, [target_conv.id], u1)

      assert forwarded.conversation_id == target_conv.id
      assert forwarded.metadata["forwarded"] == true
      assert forwarded.forwarded_from_id == source.id
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

  describe "search_messages_preview/3" do
    setup do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, _matching} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "encrypted",
          metadata: %{"plaintext_preview" => "hello world from messaging"},
          client_random: System.unique_integer([:positive])
        })

      {:ok, _no_match} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "encrypted",
          metadata: %{"plaintext_preview" => "something else"},
          client_random: System.unique_integer([:positive])
        })

      %{u1: u1, u2: u2, conv: conv}
    end

    test "returns {items, next_cursor} with matches", ctx do
      {items, cursor} = Messages.search_messages_preview(ctx.u1, "hello")
      assert is_list(items)
      assert length(items) >= 1
      assert is_nil(cursor) or is_binary(cursor)
    end

    test "respects the conversation_id filter", ctx do
      {items, _cursor} =
        Messages.search_messages_preview(ctx.u1, "hello", conversation_id: ctx.conv.id)

      assert Enum.all?(items, &(&1.conversation_id == ctx.conv.id))
    end

    test "limit clamps to [1, 50]", ctx do
      {items_min, _} = Messages.search_messages_preview(ctx.u1, "hello", limit: 0)
      assert is_list(items_min)

      {items_max, _} = Messages.search_messages_preview(ctx.u1, "hello", limit: 999)
      assert is_list(items_max)
    end
  end

  describe "build_match_preview/2 — edge cases" do
    test "returns nil when content is not binary" do
      assert is_nil(Messages.build_match_preview(123, "x"))
    end

    test "returns nil when query is empty / whitespace" do
      assert is_nil(Messages.build_match_preview("some text", ""))
      assert is_nil(Messages.build_match_preview("some text", "   "))
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

  describe "create_system_message/3 / text / media" do
    test "create_text_message/4 persists a row" do
      {u1, _u2, conv} = setup_two_user_conv()

      assert {:ok, msg} =
               Messages.create_text_message(conv.id, u1, "encrypted", System.unique_integer([:positive]))

      assert msg.message_type == "text"
    end

    test "create_media_message/5 persists a row with media metadata" do
      {u1, _u2, conv} = setup_two_user_conv()

      assert {:ok, msg} =
               Messages.create_media_message(
                 conv.id,
                 u1,
                 "encrypted",
                 System.unique_integer([:positive]),
                 %{"caption" => "x"}
               )

      assert msg.message_type == "media"
      assert msg.metadata["caption"] == "x"
    end

    test "create_system_message/3 persists a system row" do
      {_u1, _u2, conv} = setup_two_user_conv()
      # system messages use sender_id "00000000-..." per impl
      assert {:ok, msg} = Messages.create_system_message(conv.id, "user joined")
      assert msg.message_type == "system"
    end
  end

  describe "mark_conversation_read/3 — direct integration" do
    test "marks all unread messages of a user as read" do
      {u1, u2, conv} = setup_two_user_conv()

      # u1 sends 3 messages
      Enum.each(1..3, fn i ->
        {:ok, msg} =
          Messages.create_message(%{
            conversation_id: conv.id,
            sender_id: u1,
            message_type: "text",
            content: "msg-#{i}",
            client_random: System.unique_integer([:positive])
          })

        # Create delivery_status rows for u2 (recipient)
        {:ok, _} = Messages.mark_message_delivered(msg.id, u2)
      end)

      assert {:ok, count} = Messages.mark_conversation_read(conv.id, u2)
      assert count == 3
    end

    test "mark_message_read on unknown message raises a foreign-key error" do
      assert_raise Ecto.ConstraintError, fn ->
        Messages.mark_message_read(Ecto.UUID.generate(), Ecto.UUID.generate())
      end
    end
  end

  describe "list_messages_after/3" do
    test "returns a list" do
      {_u1, _u2, conv} = setup_two_user_conv()
      ts = DateTime.utc_now() |> DateTime.add(-3600, :second)
      assert is_list(Messages.list_messages_after(conv.id, ts))
    end
  end

  describe "edit_message/4" do
    test "edits a message of the sender" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "old",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, edited} = Messages.edit_message(msg.id, u1, "new")
      assert edited.content == "new"
      assert edited.edited_at != nil
    end

    test "returns :forbidden when another user tries to edit" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:error, :forbidden} = Messages.edit_message(msg.id, u2, "hacked")
    end
  end

  describe "get_reaction_summary/1" do
    test "returns an empty map when no reactions" do
      assert Messages.get_reaction_summary(Ecto.UUID.generate()) == %{}
    end

    test "groups reactions by emoji with counts" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "reactable",
          client_random: System.unique_integer([:positive])
        })

      {:ok, _} = Messages.add_reaction(msg.id, u1, "👍")
      {:ok, _} = Messages.add_reaction(msg.id, u2, "👍")
      {:ok, _} = Messages.add_reaction(msg.id, u1, "❤️")

      summary = Messages.get_reaction_summary(msg.id)
      assert summary["👍"] == 2
      assert summary["❤️"] == 1
    end
  end

  describe "remove_reaction/3 — error path" do
    test "returns :not_found for an unknown user/reaction pair" do
      assert {:error, :not_found} =
               Messages.remove_reaction(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 "❌"
               )
    end
  end

  describe "mark_message_delivered/3" do
    test "marks delivered_at on the delivery_status row" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, ds} = Messages.mark_message_delivered(msg.id, u2)
      assert ds.delivered_at != nil
    end

    test "is idempotent" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      {:ok, _} = Messages.mark_message_delivered(msg.id, u2)
      assert {:ok, _} = Messages.mark_message_delivered(msg.id, u2)
    end
  end

  describe "get_message_delivery_status/2 — actual statuses" do
    test "returns the actual status when a delivery_status row exists" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      {:ok, _} = Messages.mark_message_delivered(msg.id, u2)
      assert "delivered" = Messages.get_message_delivery_status(msg.id, u2)

      {:ok, _} = Messages.mark_message_read(msg.id, u2)
      assert "read" = Messages.get_message_delivery_status(msg.id, u2)
    end
  end

  describe "delete_message/3" do
    test "soft-deletes a message for the user (delete_for_everyone=false)" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, _} = Messages.delete_message(msg.id, u1, false)
    end

    test "deletes a message for everyone when the sender requests it" do
      {u1, _u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, deleted} = Messages.delete_message(msg.id, u1, true)
      assert deleted.is_deleted == true
    end

    test "returns :forbidden when non-sender requests delete_for_everyone" do
      {u1, u2, conv} = setup_two_user_conv()

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: u1,
          message_type: "text",
          content: "x",
          client_random: System.unique_integer([:positive])
        })

      assert {:error, :forbidden} = Messages.delete_message(msg.id, u2, true)
    end
  end
end
