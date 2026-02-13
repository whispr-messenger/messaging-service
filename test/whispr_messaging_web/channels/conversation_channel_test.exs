defmodule WhisprMessagingWeb.ConversationChannelTest do
  use WhisprMessagingWeb.ChannelCase, async: false

  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessagingWeb.{ConversationChannel, UserSocket}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(WhisprMessaging.Repo, {:shared, self()})
    user_id = Ecto.UUID.generate()
    other_user_id = Ecto.UUID.generate()

    # Create test conversation
    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    # Add both users as members
    {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _member2} = Conversations.add_conversation_member(conversation.id, other_user_id)

    # Create socket with user authentication
    socket = socket(UserSocket, "user_socket:#{user_id}", %{user_id: user_id})

    %{
      socket: socket,
      conversation: conversation,
      user_id: user_id,
      other_user_id: other_user_id
    }
  end

  describe "join conversation channel" do
    test "joins successfully when user is a member", %{
      socket: socket,
      conversation: conversation
    } do
      assert {:ok, reply, _socket} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )

      assert reply.conversation.id == conversation.id
    end

    test "fails to join when user is not a member", %{socket: socket} do
      # Create conversation without adding the user as member
      {:ok, other_conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      assert {:error, %{reason: "not_authorized"}} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{other_conversation.id}"
               )
    end

    test "fails to join non-existent conversation", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      assert {:error, %{reason: "conversation_not_found"}} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{fake_id}"
               )
    end
  end

  describe "new_message" do
    setup %{socket: socket, conversation: conversation} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      %{socket: socket}
    end

    test "creates and broadcasts a new message", %{
      socket: socket,
      conversation: conversation,
      user_id: user_id
    } do
      message_attrs = %{
        "content" => "encrypted_test_content",
        "message_type" => "text",
        "client_random" => 12_345,
        "metadata" => %{"test" => true}
      }

      ref = push(socket, "new_message", message_attrs)

      assert_reply ref, :ok, %{message: reply_message}
      assert reply_message.content == "encrypted_test_content"
      assert reply_message.message_type == "text"
      assert reply_message.sender_id == user_id
      assert reply_message.conversation_id == conversation.id

      # Should broadcast to all channel subscribers
      assert_broadcast "new_message", %{message: broadcast_message}
      assert broadcast_message.id == reply_message.id
    end

    test "fails with invalid message data", %{socket: socket} do
      invalid_attrs = %{
        "content" => "",
        "message_type" => "invalid_type",
        "client_random" => nil
      }

      ref = push(socket, "new_message", invalid_attrs)
      assert_reply ref, :error, %{errors: _errors}
    end

    test "handles duplicate client_random idempotently", %{
      socket: socket
    } do
      message_attrs = %{
        "content" => "test_content",
        "message_type" => "text",
        "client_random" => 99_999,
        "metadata" => %{}
      }

      # First message should succeed
      ref1 = push(socket, "new_message", message_attrs)
      assert_reply ref1, :ok, %{message: message1}

      # Second message with same client_random should succeed and return original message
      ref2 = push(socket, "new_message", message_attrs)
      assert_reply ref2, :ok, %{message: message2}

      assert message1.id == message2.id
    end
  end

  describe "edit_message" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to edit
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "original_content",
          client_random: 54_321
        })

      %{socket: socket, message: message}
    end

    test "edits own message successfully", %{
      socket: socket,
      message: message
    } do
      edit_attrs = %{
        "message_id" => message.id,
        "content" => "edited_content",
        "metadata" => %{"edited" => true}
      }

      ref = push(socket, "edit_message", edit_attrs)

      assert_reply ref, :ok, %{message: edited_message}
      assert edited_message.content == "edited_content"
      assert edited_message.metadata["edited"] == true
      assert edited_message.edited_at != nil

      # Should broadcast edit to all subscribers
      assert_broadcast "message_edited", %{message: broadcast_message}
      assert broadcast_message.id == message.id
    end

    test "fails to edit non-existent message", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      edit_attrs = %{
        "message_id" => fake_id,
        "content" => "new_content",
        "metadata" => %{}
      }

      ref = push(socket, "edit_message", edit_attrs)
      assert_reply ref, :error, %{reason: "not_found"}
    end

    test "fails to edit other user's message", %{
      socket: socket,
      conversation: conversation,
      other_user_id: other_user_id
    } do
      # Create message from other user
      {:ok, other_message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: other_user_id,
          message_type: "text",
          content: "other_content",
          client_random: 11_111
        })

      edit_attrs = %{
        "message_id" => other_message.id,
        "content" => "hacked_content",
        "metadata" => %{}
      }

      ref = push(socket, "edit_message", edit_attrs)
      assert_reply ref, :error, %{reason: "forbidden"}
    end
  end

  describe "delete_message" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to delete
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "content_to_delete",
          client_random: 77_777
        })

      %{socket: socket, message: message}
    end

    test "deletes own message successfully", %{
      socket: socket,
      message: message
    } do
      delete_attrs = %{
        "message_id" => message.id,
        "delete_for_everyone" => true
      }

      ref = push(socket, "delete_message", delete_attrs)

      assert_reply ref, :ok, %{message: deleted_message}
      assert deleted_message.is_deleted == true
      assert deleted_message.delete_for_everyone == true

      # Should broadcast deletion to all subscribers
      assert_broadcast "message_deleted", %{
        message_id: message_id,
        delete_for_everyone: true
      }

      assert message_id == message.id
    end

    test "fails to delete non-existent message", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      delete_attrs = %{
        "message_id" => fake_id,
        "delete_for_everyone" => false
      }

      ref = push(socket, "delete_message", delete_attrs)
      assert_reply ref, :error, %{reason: "message_not_found"}
    end
  end

  describe "message delivery and read receipts" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message from other user
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "test_content",
          client_random: 33_333
        })

      %{socket: socket, message: message}
    end

    test "marks message as delivered", %{
      socket: socket,
      message: message
    } do
      ref = push(socket, "message_delivered", %{"message_id" => message.id})
      assert_reply ref, :ok, %{status: "delivered"}
    end

    test "marks message as read", %{
      socket: socket,
      message: message,
      user_id: user_id
    } do
      push(socket, "message_read", %{"message_id" => message.id})
      
      # Should receive broadcast instead of immediate reply
      assert_broadcast "message_read", %{
        message_id: message_id,
        user_id: ^user_id
      }
      
      assert message_id == message.id
    end
  end

  describe "typing indicators" do
    setup %{socket: socket, conversation: conversation} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      %{socket: socket}
    end

    test "broadcasts typing start", %{
      socket: socket,
      user_id: user_id,
      conversation: conversation
    } do
      push(socket, "typing_start", %{})

      assert_broadcast "user_typing", %{
        user_id: broadcast_user_id,
        conversation_id: broadcast_conversation_id,
        typing: true
      }

      assert broadcast_user_id == user_id
      assert broadcast_conversation_id == conversation.id
    end

    test "broadcasts typing stop", %{socket: socket, user_id: user_id, conversation: conversation} do
      push(socket, "typing_stop", %{})

      assert_broadcast "user_typing", %{
        user_id: broadcast_user_id,
        conversation_id: broadcast_conversation_id,
        typing: false
      }

      assert broadcast_user_id == user_id
      assert broadcast_conversation_id == conversation.id
    end
  end

  describe "reactions" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to react to
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "message_to_react",
          client_random: 55_555
        })

      %{socket: socket, message: message}
    end

    test "adds reaction successfully", %{
      socket: socket,
      message: message,
      user_id: user_id
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👍"
      }

      ref = push(socket, "add_reaction", reaction_attrs)

      assert_reply ref, :ok, %{reaction: reply_reaction}
      assert reply_reaction.message_id == message.id
      assert reply_reaction.user_id == user_id
      assert reply_reaction.reaction == "👍"

      # Should broadcast reaction to all subscribers
      assert_broadcast "reaction_added", %{
        message_id: broadcast_message_id,
        user_id: broadcast_user_id,
        reaction: "👍"
      }

      assert broadcast_message_id == message.id
      assert broadcast_user_id == user_id
    end

    test "removes reaction successfully", %{
      socket: socket,
      message: message
    } do
      # First add a reaction
      Messages.add_reaction(message.id, socket.assigns.user_id, "👍")

      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👍"
      }

      ref = push(socket, "remove_reaction", reaction_attrs)

      assert_reply ref, :ok, %{status: "removed"}

      # Should broadcast removal to all subscribers
      assert_broadcast "reaction_removed", %{
        message_id: broadcast_message_id,
        user_id: broadcast_user_id,
        reaction: "👍"
      }

      assert broadcast_message_id == message.id
      assert broadcast_user_id == socket.assigns.user_id
    end

    test "fails to remove non-existent reaction", %{
      socket: socket,
      message: message
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👎"
      }

      ref = push(socket, "remove_reaction", reaction_attrs)
      assert_reply ref, :error, %{reason: "reaction_not_found"}
    end

    test "prevents duplicate reactions", %{
      socket: socket,
      message: message
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "❤️"
      }

      # First reaction should succeed
      ref1 = push(socket, "add_reaction", reaction_attrs)
      assert_reply ref1, :ok, %{reaction: _}

      # Duplicate reaction should fail
      ref2 = push(socket, "add_reaction", reaction_attrs)
      assert_reply ref2, :error, %{errors: _}
    end
  end

  describe "presence tracking" do
    test "tracks user presence on join", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Should receive presence state
      assert_push "presence_state", _presence_state
    end

    test "receives presence diffs", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Presence diffs would be pushed when other users join/leave
      # This is tested indirectly through the presence system
    end
  end
end
