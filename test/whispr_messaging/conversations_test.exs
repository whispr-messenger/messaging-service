defmodule WhisprMessaging.ConversationsTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember, ConversationSettings}

  describe "conversations" do
    test "create_conversation/1 creates a conversation with valid attributes" do
      attrs = %{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      }

      assert {:ok, %Conversation{} = conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "direct"
      assert conversation.metadata == %{"test" => true}
      assert conversation.is_active == true
      assert conversation.external_group_id == nil
    end

    test "create_conversation/1 creates a group conversation with external_group_id" do
      external_group_id = Ecto.UUID.generate()

      attrs = %{
        type: "group",
        external_group_id: external_group_id,
        metadata: %{"name" => "Test Group"},
        is_active: true
      }

      assert {:ok, %Conversation{} = conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "group"
      assert conversation.external_group_id == external_group_id
      assert conversation.metadata["name"] == "Test Group"
    end

    test "create_conversation/1 fails with invalid attributes" do
      attrs = %{
        type: "invalid_type",
        metadata: "invalid_metadata"
      }

      assert {:error, %Ecto.Changeset{}} = Conversations.create_conversation(attrs)
    end

    test "get_conversation/1 returns conversation when it exists" do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

      assert {:ok, fetched_conversation} = Conversations.get_conversation(conversation.id)
      assert fetched_conversation.id == conversation.id
    end

    test "get_conversation/1 returns error when conversation doesn't exist" do
      assert {:error, :not_found} = Conversations.get_conversation(Ecto.UUID.generate())
    end

    test "get_conversation_by_external_group_id/1 finds conversation by external ID" do
      external_group_id = Ecto.UUID.generate()

      {:ok, conversation} = Conversations.create_conversation(%{
        type: "group",
        external_group_id: external_group_id,
        metadata: %{},
        is_active: true
      })

      assert {:ok, found_conversation} = Conversations.get_conversation_by_external_group_id(external_group_id)
      assert found_conversation.id == conversation.id
    end

    test "update_conversation/2 updates conversation attributes" do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"original" => true},
        is_active: true
      })

      new_attrs = %{
        metadata: %{"updated" => true},
        is_active: false
      }

      assert {:ok, updated_conversation} = Conversations.update_conversation(conversation, new_attrs)
      assert updated_conversation.metadata == %{"updated" => true}
      assert updated_conversation.is_active == false
    end

    test "deactivate_conversation/1 marks conversation as inactive" do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

      assert {:ok, deactivated_conversation} = Conversations.deactivate_conversation(conversation)
      assert deactivated_conversation.is_active == false
    end

    test "create_direct_conversation/3 creates conversation with two members" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      assert {:ok, conversation} = Conversations.create_direct_conversation(
        user1_id,
        user2_id,
        %{"created_by" => "test"}
      )

      assert conversation.type == "direct"
      assert conversation.metadata["created_by"] == "test"

      # Check that both users were added as members
      members = Conversations.list_conversation_members(conversation.id)
      assert length(members) == 2

      member_user_ids = Enum.map(members, & &1.user_id)
      assert user1_id in member_user_ids
      assert user2_id in member_user_ids
    end

    test "create_group_conversation/4 creates conversation with multiple members" do
      creator_id = Ecto.UUID.generate()
      member_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      external_group_id = Ecto.UUID.generate()

      assert {:ok, conversation} = Conversations.create_group_conversation(
        creator_id,
        member_ids,
        external_group_id,
        %{"name" => "Test Group"}
      )

      assert conversation.type == "group"
      assert conversation.external_group_id == external_group_id
      assert conversation.metadata["name"] == "Test Group"

      # Check that all users were added (creator + members)
      members = Conversations.list_conversation_members(conversation.id)
      assert length(members) == 3

      member_user_ids = Enum.map(members, & &1.user_id)
      assert creator_id in member_user_ids
      Enum.each(member_ids, fn member_id ->
        assert member_id in member_user_ids
      end)
    end

    test "find_or_create_direct_conversation/2 finds existing conversation" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      # Create initial conversation
      {:ok, conversation1} = Conversations.create_direct_conversation(user1_id, user2_id)

      # Try to create again - should return existing
      {:ok, conversation2} = Conversations.find_or_create_direct_conversation(user1_id, user2_id)

      assert conversation1.id == conversation2.id
    end

    test "find_or_create_direct_conversation/2 creates new conversation when none exists" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      assert {:ok, conversation} = Conversations.find_or_create_direct_conversation(user1_id, user2_id)
      assert conversation.type == "direct"
    end
  end

  describe "conversation members" do
    setup do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "group",
        metadata: %{},
        is_active: true
      })

      %{conversation: conversation}
    end

    test "add_conversation_member/3 adds a member to conversation", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()

      assert {:ok, %ConversationMember{} = member} = Conversations.add_conversation_member(
        conversation.id,
        user_id
      )

      assert member.conversation_id == conversation.id
      assert member.user_id == user_id
      assert member.is_active == true
      assert member.joined_at != nil
      assert member.settings == ConversationMember.default_settings()
    end

    test "add_conversation_member/3 allows custom settings", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      custom_settings = %{"notifications" => false}

      assert {:ok, member} = Conversations.add_conversation_member(
        conversation.id,
        user_id,
        custom_settings
      )

      assert member.settings == custom_settings
    end

    test "add_conversation_member/3 prevents duplicate members", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()

      # First addition should succeed
      assert {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      # Second addition should fail
      assert {:error, %Ecto.Changeset{}} = Conversations.add_conversation_member(
        conversation.id,
        user_id
      )
    end

    test "get_conversation_member/2 returns member when exists", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conversation.id, user_id)

      fetched_member = Conversations.get_conversation_member(conversation.id, user_id)
      assert fetched_member.id == member.id
    end

    test "get_conversation_member/2 returns nil when member doesn't exist", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      assert Conversations.get_conversation_member(conversation.id, user_id) == nil
    end

    test "list_conversation_members/1 returns all active members", %{conversation: conversation} do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      members = Conversations.list_conversation_members(conversation.id)
      assert length(members) == 2

      member_user_ids = Enum.map(members, & &1.user_id)
      assert user1_id in member_user_ids
      assert user2_id in member_user_ids
    end

    test "count_conversation_members/1 returns correct count", %{conversation: conversation} do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      assert Conversations.count_conversation_members(conversation.id) == 2
    end

    test "remove_conversation_member/2 deactivates member", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conversation.id, user_id)

      assert {:ok, updated_member} = Conversations.remove_conversation_member(conversation.id, user_id)
      assert updated_member.is_active == false

      # Should not appear in active members list
      active_members = Conversations.list_conversation_members(conversation.id)
      assert length(active_members) == 0
    end

    test "mark_member_read/2 updates last_read_at", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conversation.id, user_id)

      assert member.last_read_at == nil

      timestamp = DateTime.utc_now()
      assert {:ok, updated_member} = Conversations.mark_member_read(member, timestamp)
      assert updated_member.last_read_at == timestamp
    end

    test "update_member_settings/2 updates member settings", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conversation.id, user_id)

      new_settings = %{"notifications" => false, "sound_enabled" => false}

      assert {:ok, updated_member} = Conversations.update_member_settings(member, new_settings)
      assert updated_member.settings == new_settings
    end

    test "member_of_conversation?/2 checks membership correctly", %{conversation: conversation} do
      user_id = Ecto.UUID.generate()
      non_member_id = Ecto.UUID.generate()

      # User is not a member initially
      assert Conversations.member_of_conversation?(conversation.id, user_id) == false

      # Add user as member
      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)
      assert Conversations.member_of_conversation?(conversation.id, user_id) == true

      # Non-member should still return false
      assert Conversations.member_of_conversation?(conversation.id, non_member_id) == false

      # Remove member
      {:ok, _} = Conversations.remove_conversation_member(conversation.id, user_id)
      assert Conversations.member_of_conversation?(conversation.id, user_id) == false
    end
  end

  describe "user conversations" do
    setup do
      user_id = Ecto.UUID.generate()

      # Create multiple conversations for the user
      {:ok, conv1} = Conversations.create_direct_conversation(
        user_id,
        Ecto.UUID.generate(),
        %{"name" => "Conversation 1"}
      )

      {:ok, conv2} = Conversations.create_direct_conversation(
        user_id,
        Ecto.UUID.generate(),
        %{"name" => "Conversation 2"}
      )

      %{user_id: user_id, conversations: [conv1, conv2]}
    end

    test "list_user_conversations/1 returns user's conversations", %{
      user_id: user_id,
      conversations: conversations
    } do
      {:ok, user_conversations} = Conversations.list_user_conversations(user_id)

      assert length(user_conversations) == 2

      conversation_ids = Enum.map(user_conversations, & &1.id)
      Enum.each(conversations, fn conv ->
        assert conv.id in conversation_ids
      end)
    end

    test "get_conversation_summaries/1 returns conversation summaries", %{
      user_id: user_id
    } do
      {:ok, summaries} = Conversations.get_conversation_summaries(user_id)

      assert length(summaries) == 2
      Enum.each(summaries, fn summary ->
        assert Map.has_key?(summary, :id)
        assert Map.has_key?(summary, :type)
        assert Map.has_key?(summary, :unread_count)
        assert Map.has_key?(summary, :member_count)
      end)
    end

    test "get_user_active_conversations/1 returns conversation IDs", %{
      user_id: user_id,
      conversations: conversations
    } do
      {:ok, conversation_ids} = Conversations.get_user_active_conversations(user_id)

      assert length(conversation_ids) == 2
      Enum.each(conversations, fn conv ->
        assert conv.id in conversation_ids
      end)
    end
  end

  describe "conversation settings" do
    setup do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "group",
        metadata: %{},
        is_active: true
      })

      %{conversation: conversation}
    end

    test "get_conversation_settings/1 creates default settings if none exist", %{
      conversation: conversation
    } do
      assert {:ok, %ConversationSettings{} = settings} = Conversations.get_conversation_settings(
        conversation.id
      )

      assert settings.conversation_id == conversation.id
      assert is_map(settings.settings)
      assert settings.settings["allow_editing"] == true
    end

    test "create_conversation_settings/2 creates custom settings", %{
      conversation: conversation
    } do
      custom_settings = %{"allow_media" => false, "custom_setting" => "value"}

      assert {:ok, settings} = Conversations.create_conversation_settings(
        conversation.id,
        custom_settings
      )

      # Should merge with defaults
      assert settings.settings["allow_media"] == false
      assert settings.settings["custom_setting"] == "value"
      assert settings.settings["allow_editing"] == true  # Default value
    end

    test "update_conversation_settings/2 updates existing settings", %{
      conversation: conversation
    } do
      # Create initial settings
      {:ok, settings} = Conversations.get_conversation_settings(conversation.id)

      new_settings = %{"allow_reactions" => false, "new_setting" => "test"}

      assert {:ok, updated_settings} = Conversations.update_conversation_settings(
        settings,
        new_settings
      )

      assert updated_settings.settings["allow_reactions"] == false
      assert updated_settings.settings["new_setting"] == "test"
    end
  end

  describe "conversation analytics" do
    setup do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "group",
        metadata: %{},
        is_active: true
      })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      %{conversation: conversation, user1_id: user1_id, user2_id: user2_id}
    end

    test "get_conversation_stats/1 returns basic statistics", %{
      conversation: conversation
    } do
      stats = Conversations.get_conversation_stats(conversation.id)

      assert stats.member_count == 2
      assert stats.message_count == 0  # No messages created yet
      assert stats.last_activity == nil
    end

    test "search_conversations/2 finds conversations by metadata", %{
      conversation: conversation
    } do
      # Update conversation with searchable metadata
      {:ok, _} = Conversations.update_conversation(conversation, %{
        metadata: %{"name" => "Searchable Group", "topic" => "testing"}
      })

      results = Conversations.search_conversations("Searchable")
      assert length(results) == 1
      assert Enum.at(results, 0).id == conversation.id

      results = Conversations.search_conversations("nonexistent")
      assert length(results) == 0
    end
  end
end