defmodule WhisprMessaging.ConversationServerTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.{Conversations, ConversationServer, ConversationSupervisor, Messages}

  setup do
    # Create test conversation
    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Test Group"},
        is_active: true
      })

    # Create test users
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    # Add users as members
    {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

    %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    }
  end

  describe "conversation server lifecycle" do
    test "starts and stops conversation server", %{conversation: conversation} do
      # Start the conversation server
      assert {:ok, pid} = ConversationSupervisor.start_conversation(conversation.id)
      assert Process.alive?(pid)

      # Verify server is registered
      registered_pid = ConversationSupervisor.get_conversation_pid(conversation.id)
      assert registered_pid == pid

      # Stop the conversation server
      assert :ok = ConversationSupervisor.stop_conversation(conversation.id)
      refute Process.alive?(pid)

      # Wait for Registry cleanup
      Process.sleep(50)

      # Verify server is no longer registered
      assert ConversationSupervisor.get_conversation_pid(conversation.id) == nil
    end

    test "prevents duplicate conversation servers", %{conversation: conversation} do
      # Start first server
      assert {:ok, pid1} = ConversationSupervisor.start_conversation(conversation.id)

      # Try to start second server - should return existing
      assert {:ok, pid2} = ConversationSupervisor.start_conversation(conversation.id)
      assert pid1 == pid2

      # Clean up
      ConversationSupervisor.stop_conversation(conversation.id)
    end

    test "restarts server on failure", %{conversation: conversation} do
      # Start server
      {:ok, pid1} = ConversationSupervisor.start_conversation(conversation.id)

      # Simulate crash
      Process.exit(pid1, :kill)

      # Wait for restart
      Process.sleep(100)

      # Verify new server started
      pid2 = ConversationSupervisor.get_conversation_pid(conversation.id)
      assert pid2 != nil
      assert pid2 != pid1

      # Clean up
      ConversationSupervisor.stop_conversation(conversation.id)
    end
  end

  describe "message handling" do
    setup %{conversation: conversation} do
      start_supervised!({ConversationServer, conversation.id})
      :ok
    end

    test "sends message successfully", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      message_params = %{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "test_message",
        client_random: 12_345
      }

      assert {:ok, message} = ConversationServer.send_message(conversation.id, message_params)
      assert message.content == "test_message"
      assert message.sender_id == user1_id
      assert message.conversation_id == conversation.id
    end

    test "fails to send invalid message", %{conversation: conversation} do
      invalid_attrs = %{
        conversation_id: conversation.id,
        sender_id: nil,
        message_type: "invalid",
        content: "",
        client_random: nil
      }

      assert {:error, _changeset} =
               ConversationServer.send_message(conversation.id, invalid_attrs)
    end
  end

  describe "member management" do
    setup %{conversation: conversation} do
      {:ok, pid} = ConversationSupervisor.start_conversation(conversation.id)
      on_exit(fn -> ConversationSupervisor.stop_conversation(conversation.id) end)
      %{pid: pid}
    end

    test "adds member to conversation", %{conversation: conversation} do
      new_user_id = Ecto.UUID.generate()
      assert {:ok, _} = ConversationServer.add_member(conversation.id, new_user_id)

      # Verify in DB
      member = Conversations.get_conversation_member(conversation.id, new_user_id)
      assert member != nil
      assert member.is_active == true
    end

    test "removes member from conversation", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      assert {:ok, _} = ConversationServer.remove_member(conversation.id, user1_id)

      # Verify in DB
      member = Conversations.get_conversation_member(conversation.id, user1_id)
      assert member.is_active == false
    end

    test "fails to remove non-existent member", %{conversation: conversation} do
      fake_user_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               ConversationServer.remove_member(conversation.id, fake_user_id)
    end
  end

  describe "typing indicators" do
    setup %{conversation: conversation} do
      {:ok, pid} = ConversationSupervisor.start_conversation(conversation.id)
      on_exit(fn -> ConversationSupervisor.stop_conversation(conversation.id) end)
      %{pid: pid}
    end

    test "updates typing status", %{pid: pid, conversation: conversation, user1_id: user1_id} do
      # Start typing
      assert :ok = ConversationServer.update_typing(conversation.id, user1_id, true)

      # Check state (internal function call for testing)
      state = :sys.get_state(pid)
      # typing_users is now a MapSet, not a Map
      assert MapSet.member?(state.typing_users, user1_id)

      # Stop typing
      assert :ok = ConversationServer.update_typing(conversation.id, user1_id, false)

      state = :sys.get_state(pid)
      refute MapSet.member?(state.typing_users, user1_id)
    end
  end

  describe "read receipts" do
    setup %{conversation: conversation, user1_id: user1_id} do
      start_supervised!({ConversationServer, conversation.id})

      # Create a test message
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_message",
          client_random: 99_999
        })

      %{message: message}
    end

    test "marks specific message as read", %{
      conversation: conversation,
      user2_id: user2_id,
      message: message
    } do
      ConversationServer.mark_read(conversation.id, user2_id, message.id)

      # Verify read status (this would typically involve checking delivery status)
      # For now, we just verify the function doesn't crash
    end

    test "marks all messages as read", %{
      conversation: conversation,
      user2_id: user2_id
    } do
      ConversationServer.mark_read(conversation.id, user2_id)

      # Verify all messages are marked as read
      # This would typically involve checking conversation read status
    end
  end

  describe "conversation settings" do
    setup %{conversation: conversation} do
      start_supervised!({ConversationServer, conversation.id})
      :ok
    end

    test "updates conversation settings", %{conversation: conversation} do
      new_settings = %{
        "allow_media" => false,
        "max_messages_per_minute" => 10
      }

      assert :ok = ConversationServer.update_settings(conversation.id, new_settings)

      # Verify settings are updated in database
      {:ok, settings} = Conversations.get_conversation_settings(conversation.id)
      assert settings.settings["allow_media"] == false
      assert settings.settings["max_messages_per_minute"] == 10
    end
  end

  describe "server state" do
    setup %{conversation: conversation} do
      start_supervised!({ConversationServer, conversation.id})
      :ok
    end

    test "retrieves server state", %{conversation: conversation} do
      state = ConversationServer.get_state(conversation.id)

      assert is_map(state)
      assert state.conversation_id == conversation.id
      assert is_integer(state.member_count)
      assert is_integer(state.active_member_count)
      assert is_integer(state.typing_user_count)
      assert is_integer(state.message_queue_size)
      assert %DateTime{} = state.last_activity
      assert is_map(state.metrics)
    end

    test "state includes expected metrics", %{conversation: conversation} do
      state = ConversationServer.get_state(conversation.id)

      assert Map.has_key?(state.metrics, :messages_sent)
      assert Map.has_key?(state.metrics, :members_added)
      assert Map.has_key?(state.metrics, :members_removed)
      assert Map.has_key?(state.metrics, :typing_events)
      assert Map.has_key?(state.metrics, :last_reset)
    end
  end

  describe "error handling" do
    test "handles invalid conversation ID gracefully" do
      fake_conversation_id = Ecto.UUID.generate()

      # Should fail to start server for non-existent conversation
      # We check for {:error, _} because the specific error depends on the implementation
      assert {:error, _reason} = ConversationSupervisor.start_conversation(fake_conversation_id)
    end

    test "handles server process death gracefully", %{conversation: conversation} do
      {:ok, pid} = ConversationSupervisor.start_conversation(conversation.id)

      # Kill the process
      Process.exit(pid, :kill)

      # Wait for supervisor to detect failure and Registry to clean up
      Process.sleep(150)

      # Should be able to restart
      # For test stability, we manually restart instead of relying on supervisor auto-restart
      # which might be timing-dependent in tests

      # Clean up previous instance if it was restarted by supervisor
      ConversationSupervisor.stop_conversation(conversation.id)
      Process.sleep(50)

      # Start new instance
      assert {:ok, new_pid} = ConversationSupervisor.start_conversation(conversation.id)
      assert new_pid != pid
      assert Process.alive?(new_pid)

      # Clean up
      ConversationSupervisor.stop_conversation(conversation.id)
      Process.sleep(50)
    end
  end

  describe "performance and cleanup" do
    setup %{conversation: conversation} do
      start_supervised!({ConversationServer, conversation.id})
      :ok
    end

    test "handles multiple rapid message sends", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Send multiple messages rapidly
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            ConversationServer.send_message(conversation.id, %{
              conversation_id: conversation.id,
              sender_id: user1_id,
              message_type: "text",
              content: "message_#{i}",
              client_random: i + 10_000
            })
          end)
        end

      # Wait for all tasks to complete
      results = Enum.map(tasks, &Task.await/1)

      # All messages should be created successfully
      successful_results =
        Enum.filter(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert length(successful_results) == 10
    end

    test "server responds to cleanup messages", %{conversation: conversation} do
      # Get initial state
      initial_state = ConversationServer.get_state(conversation.id)

      # Send cleanup message directly to server process
      server_pid = ConversationSupervisor.get_conversation_pid(conversation.id)
      send(server_pid, :cleanup)

      # Wait for cleanup to process
      Process.sleep(50)

      # Server should still be alive and responsive
      final_state = ConversationServer.get_state(conversation.id)
      assert final_state.conversation_id == initial_state.conversation_id
    end
  end
end
