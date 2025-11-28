defmodule WhisprMessaging.MessagesTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.{Messages, Conversations}
  alias WhisprMessaging.Messages.{Message, DeliveryStatus, MessageReaction}

  describe "messages" do
    setup do
      # Create test conversation
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{"test" => true},
          is_active: true
        })

      # Add test members
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      %{
        conversation: conversation,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "create_message/1 creates a message with valid attributes", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      attrs = %{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "encrypted_test_content",
        client_random: 12345,
        metadata: %{"test" => true}
      }

      assert {:ok, %Message{} = message} = Messages.create_message(attrs)
      assert message.conversation_id == conversation.id
      assert message.sender_id == user1_id
      assert message.message_type == "text"
      assert message.content == "encrypted_test_content"
      assert message.client_random == 12345
      assert message.metadata == %{"test" => true}
      assert message.is_deleted == false
      assert message.sent_at != nil
    end

    test "create_message/1 fails with invalid attributes" do
      attrs = %{
        conversation_id: Ecto.UUID.generate(),
        sender_id: nil,
        message_type: "invalid_type",
        content: "",
        client_random: nil
      }

      assert {:error, %Ecto.Changeset{}} = Messages.create_message(attrs)
    end

    test "create_message/1 enforces unique client_random per sender", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      attrs = %{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "test_content",
        client_random: 12345
      }

      # First message should succeed
      assert {:ok, _message1} = Messages.create_message(attrs)

      # Second message with same client_random should fail
      assert {:error, %Ecto.Changeset{}} = Messages.create_message(attrs)
    end

    test "get_message/1 returns message when it exists", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12345
        })

      assert {:ok, fetched_message} = Messages.get_message(message.id)
      assert fetched_message.id == message.id
    end

    test "get_message/1 returns error when message doesn't exist" do
      assert {:error, :not_found} = Messages.get_message(Ecto.UUID.generate())
    end

    test "edit_message/4 updates message content", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 12345
        })

      new_content = "updated_content"
      new_metadata = %{"edited" => true}

      assert {:ok, updated_message} =
               Messages.edit_message(message.id, user1_id, new_content, new_metadata)

      assert updated_message.content == new_content
      assert updated_message.metadata["edited"] == true
      assert updated_message.edited_at != nil
    end

    test "edit_message/4 fails when user is not the sender", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 12345
        })

      assert {:error, :unauthorized} = Messages.edit_message(message.id, user2_id, "new_content")
    end

    test "delete_message/3 soft deletes a message", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12345
        })

      assert {:ok, deleted_message} = Messages.delete_message(message.id, user1_id, true)
      assert deleted_message.is_deleted == true
      assert deleted_message.delete_for_everyone == true
    end

    test "list_recent_messages/3 returns messages in descending order", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create multiple messages
      messages =
        for i <- 1..5 do
          {:ok, message} =
            Messages.create_message(%{
              conversation_id: conversation.id,
              sender_id: user1_id,
              message_type: "text",
              content: "content_#{i}",
              client_random: i
            })

          message
        end

      recent_messages = Messages.list_recent_messages(conversation.id, 3)

      assert length(recent_messages) == 3
      # Should be in descending order by sent_at
      assert Enum.at(recent_messages, 0).client_random == 5
      assert Enum.at(recent_messages, 1).client_random == 4
      assert Enum.at(recent_messages, 2).client_random == 3
    end

    test "count_unread_messages/3 counts unread messages correctly", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # Create messages from user1
      for i <- 1..3 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "content_#{i}",
          client_random: i
        })
      end

      # Count unread messages for user2 (should be 3)
      unread_count = Messages.count_unread_messages(conversation.id, user2_id)
      assert unread_count == 3
    end
  end

  describe "delivery statuses" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12345
        })

      %{
        conversation: conversation,
        message: message,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "create_delivery_statuses_for_conversation/3 creates statuses for all members except sender",
         %{
           conversation: conversation,
           message: message,
           user1_id: user1_id
         } do
      assert {:ok, count} =
               Messages.create_delivery_statuses_for_conversation(
                 message.id,
                 conversation.id,
                 user1_id
               )

      # Should create 1 delivery status (for user2, excluding sender user1)
      assert count == 1
    end

    test "mark_message_delivered/3 updates delivery status", %{
      message: message,
      user2_id: user2_id
    } do
      # First mark as delivered
      assert {:ok, delivery_status} = Messages.mark_message_delivered(message.id, user2_id)
      assert delivery_status.delivered_at != nil
      assert delivery_status.read_at == nil
    end

    test "mark_message_read/3 updates read status and sets delivered if not set", %{
      message: message,
      user2_id: user2_id
    } do
      # Mark as read without marking delivered first
      assert {:ok, delivery_status} = Messages.mark_message_read(message.id, user2_id)
      assert delivery_status.read_at != nil
      # Should be set automatically
      assert delivery_status.delivered_at != nil
    end

    test "mark_conversation_read/3 marks all messages as read", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # Create multiple messages
      for i <- 1..3 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "content_#{i}",
          client_random: i + 1000
        })
      end

      # Mark all as read for user2
      assert {:ok, count} = Messages.mark_conversation_read(conversation.id, user2_id)
      # Should mark at least the 3 new messages
      assert count >= 3
    end
  end

  describe "reactions" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12345
        })

      %{
        conversation: conversation,
        message: message,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "add_reaction/3 adds a reaction to a message", %{
      message: message,
      user2_id: user2_id
    } do
      assert {:ok, reaction} = Messages.add_reaction(message.id, user2_id, "👍")
      assert reaction.message_id == message.id
      assert reaction.user_id == user2_id
      assert reaction.reaction == "👍"
    end

    test "add_reaction/3 prevents duplicate reactions", %{
      message: message,
      user2_id: user2_id
    } do
      # First reaction should succeed
      assert {:ok, _reaction} = Messages.add_reaction(message.id, user2_id, "👍")

      # Duplicate reaction should fail
      assert {:error, %Ecto.Changeset{}} = Messages.add_reaction(message.id, user2_id, "👍")
    end

    test "remove_reaction/3 removes a reaction", %{
      message: message,
      user2_id: user2_id
    } do
      # Add reaction first
      {:ok, _reaction} = Messages.add_reaction(message.id, user2_id, "👍")

      # Remove reaction
      assert {:ok, :deleted} = Messages.remove_reaction(message.id, user2_id, "👍")

      # Try to remove again (should fail)
      assert {:error, :not_found} = Messages.remove_reaction(message.id, user2_id, "👍")
    end

    test "get_reaction_summary/1 returns reaction counts", %{
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # Add multiple reactions
      Messages.add_reaction(message.id, user1_id, "👍")
      Messages.add_reaction(message.id, user2_id, "👍")
      Messages.add_reaction(message.id, user1_id, "❤️")

      summary = Messages.get_reaction_summary(message.id)

      assert summary["👍"] == 2
      assert summary["❤️"] == 1
    end
  end

  describe "message helpers" do
    test "create_text_message/5 creates a text message" do
      conversation_id = Ecto.UUID.generate()
      sender_id = Ecto.UUID.generate()

      assert %Ecto.Changeset{valid?: true} =
               Messages.create_text_message(
                 conversation_id,
                 sender_id,
                 "encrypted_content",
                 12345,
                 %{"test" => true}
               )
    end

    test "create_system_message/3 creates a system message" do
      conversation_id = Ecto.UUID.generate()

      assert %Ecto.Changeset{valid?: true} =
               Messages.create_system_message(
                 conversation_id,
                 "User joined",
                 %{"action" => "join"}
               )
    end
  end
end
