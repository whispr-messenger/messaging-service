defmodule WhisprMessaging.MessagesTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessaging.Messages.{DeliveryStatus, Message, MessageReaction}

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
        client_random: 12_345,
        metadata: %{"test" => true}
      }

      assert {:ok, %Message{} = message} = Messages.create_message(attrs)
      assert message.conversation_id == conversation.id
      assert message.sender_id == user1_id
      assert message.message_type == "text"
      assert message.content == "encrypted_test_content"
      assert message.client_random == 12_345
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
        client_random: 12_345
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
          client_random: 12_345
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
          client_random: 12_345
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
          client_random: 12_345
        })

      assert {:error, :forbidden} = Messages.edit_message(message.id, user2_id, "new_content")
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
          client_random: 12_345
        })

      assert {:ok, deleted_message} = Messages.delete_message(message.id, user1_id, true)
      assert deleted_message.is_deleted == true
      assert deleted_message.delete_for_everyone == true
    end

    test "list_recent_messages/3 returns messages in descending order", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create multiple messages with explicit timestamps to ensure order
      base_time = DateTime.utc_now() |> DateTime.truncate(:second)

      messages =
        for i <- 1..5 do
          {:ok, message} =
            Messages.create_message(%{
              conversation_id: conversation.id,
              sender_id: user1_id,
              message_type: "text",
              content: "content_#{i}",
              client_random: i,
              sent_at: DateTime.add(base_time, -i, :second)
            })

          message
        end

      # Messages created:
      # 1: now - 1s (newest)
      # 2: now - 2s
      # 3: now - 3s
      # 4: now - 4s
      # 5: now - 5s (oldest)
      # Wait, I am subtracting i.
      # i=1 => -1s
      # i=5 => -5s.
      # So message 1 is NEWEST. Message 5 is OLDEST.
      # Descending order (newest first) should be: 1, 2, 3, 4, 5.

      recent_messages = Messages.list_recent_messages(conversation.id, 3)

      assert length(recent_messages) == 3
      # Should be in descending order by sent_at
      # 1 is newest.
      assert Enum.at(recent_messages, 0).client_random == 1
      assert Enum.at(recent_messages, 1).client_random == 2
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
          client_random: 12_345
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

    test "mark_conversation_read/3 marks all messages as read" do
      conversation_id = Ecto.UUID.generate()
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      # Create real conversation for DB constraints
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      # Add members
      {:ok, _} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user2_id)

      conversation_id = conversation.id

      # Create messages
      for i <- 1..3 do
        {:ok, message} =
          Messages.create_message(%{
            conversation_id: conversation_id,
            sender_id: user1_id,
            message_type: "text",
            content: "msg #{i}",
            client_random: i
          })

        # Create delivery status for user2
        Messages.create_delivery_statuses_for_conversation(message.id, conversation_id, user1_id)
      end

      # Mark as read
      assert {:ok, count} = Messages.mark_conversation_read(conversation_id, user2_id)
      assert count == 3

      # Verify timestamps
      statuses = WhisprMessaging.Repo.all(WhisprMessaging.Messages.DeliveryStatus)
      assert length(statuses) == 3
      assert Enum.all?(statuses, fn s -> s.read_at != nil end)
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
          client_random: 12_345
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

      # We need a real conversation for foreign key constraints
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      # Update conversation_id to real one
      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_text_message(
                 conversation_id,
                 sender_id,
                 "encrypted_content",
                 12_345,
                 %{
                   "test" => true
                 }
               )

      assert message.message_type == "text"
      assert message.content == "encrypted_content"
      assert message.client_random == 12_345
      assert message.metadata["test"] == true
    end

    test "create_media_message/5 creates a media message" do
      conversation_id = Ecto.UUID.generate()
      sender_id = Ecto.UUID.generate()

      # We need a real conversation
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_media_message(
                 conversation_id,
                 sender_id,
                 "encrypted_url",
                 67_890,
                 %{
                   "width" => 800
                 }
               )

      assert message.message_type == "media"
      assert message.content == "encrypted_url"
      assert message.metadata["width"] == 800
    end

    test "create_system_message/3 creates a system message" do
      conversation_id = Ecto.UUID.generate()

      # We need a real conversation
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "System Group"},
          is_active: true
        })

      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_system_message(
                 conversation_id,
                 "User joined",
                 %{"action" => "join"}
               )

      assert message.message_type == "system"
      assert message.content == "User joined"
      assert message.sender_id == "00000000-0000-0000-0000-000000000000"
    end
  end
end
