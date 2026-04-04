defmodule WhisprMessaging.ConversationsTest do
  use WhisprMessaging.DataCase

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.Conversation

  describe "create_conversation/1" do
    test "creates a direct conversation successfully" do
      attrs = %{
        type: "direct",
        metadata: %{},
        is_active: true
      }

      assert {:ok, %Conversation{} = conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "direct"
      assert conversation.is_active == true
    end

    test "creates a group conversation with name" do
      attrs = %{
        type: "group",
        metadata: %{"name" => "Team Chat"},
        is_active: true
      }

      assert {:ok, %Conversation{} = conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "group"
      assert conversation.metadata["name"] == "Team Chat"
    end
  end

  describe "get_conversation/1" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      %{conversation: conversation}
    end

    test "returns conversation when it exists", %{conversation: conversation} do
      assert {:ok, found} = Conversations.get_conversation(conversation.id)
      assert found.id == conversation.id
    end

    test "returns error when conversation does not exist" do
      assert {:error, :not_found} = Conversations.get_conversation(Ecto.UUID.generate())
    end
  end

  describe "create_direct_conversation/3" do
    test "creates conversation with two members" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      assert {:ok, conversation} = Conversations.create_direct_conversation(user1_id, user2_id)
      assert conversation.type == "direct"

      members = Conversations.list_conversation_members(conversation.id)
      assert length(members) == 2
    end

    test "returns existing conversation if it already exists" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      assert {:ok, conversation1} = Conversations.create_direct_conversation(user1_id, user2_id)
      assert {:ok, conversation2} = Conversations.create_direct_conversation(user1_id, user2_id)

      assert conversation1.id == conversation2.id
    end

    test "reactivates existing conversation if it was inactive" do
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, conversation} = Conversations.create_direct_conversation(user1_id, user2_id)
      Conversations.update_conversation(conversation, %{is_active: false})

      assert {:ok, reactivated} = Conversations.create_direct_conversation(user1_id, user2_id)
      assert reactivated.id == conversation.id
      assert reactivated.is_active == true
    end

    test "cannot create conversation with yourself" do
      user_id = Ecto.UUID.generate()
      assert {:error, changeset} = Conversations.create_direct_conversation(user_id, user_id)
      assert "Cannot create conversation with yourself" in errors_on(changeset).base
    end
  end

  describe "update_conversation/2" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Old Name"},
          is_active: true
        })

      %{conversation: conversation}
    end

    test "updates conversation name", %{conversation: conversation} do
      assert {:ok, updated} =
               Conversations.update_conversation(conversation, %{
                 metadata: %{"name" => "New Name"}
               })

      assert updated.metadata["name"] == "New Name"
    end
  end

  # ---------------------------------------------------------------------------
  # Conversation member settings tests (WHISPR-467)
  # ---------------------------------------------------------------------------

  describe "get_conversation_member_settings/2" do
    setup do
      user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "returns default settings for a new member", %{conversation: c, user_id: user_id} do
      assert {:ok, settings} = Conversations.get_conversation_member_settings(c.id, user_id)
      assert settings["notifications"] == true
      assert settings["is_muted"] == false
      assert settings["custom_name"] == nil
    end

    test "returns :not_member for non-member", %{conversation: c} do
      stranger = Ecto.UUID.generate()

      assert {:error, :not_member} =
               Conversations.get_conversation_member_settings(c.id, stranger)
    end
  end

  describe "update_conversation_member_settings/3" do
    setup do
      user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "updates allowed settings", %{conversation: c, user_id: user_id} do
      assert {:ok, _} =
               Conversations.update_conversation_member_settings(c.id, user_id, %{
                 "is_muted" => true,
                 "custom_name" => "My Friend"
               })

      {:ok, settings} = Conversations.get_conversation_member_settings(c.id, user_id)
      assert settings["is_muted"] == true
      assert settings["custom_name"] == "My Friend"
    end

    test "ignores disallowed keys (e.g. role)", %{conversation: c, user_id: user_id} do
      # "role" is an internal key and should not be writable via this API
      assert {:ok, _} =
               Conversations.update_conversation_member_settings(c.id, user_id, %{
                 "role" => "admin"
               })

      # Member is still a regular member
      member = Conversations.get_conversation_member(c.id, user_id)
      assert Map.get(member.settings, "role", "member") == "member"
    end

    test "returns :not_member for non-member", %{conversation: c} do
      stranger = Ecto.UUID.generate()

      assert {:error, :not_member} =
               Conversations.update_conversation_member_settings(c.id, stranger, %{
                 "is_muted" => true
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Conversation search tests (WHISPR-468)
  # ---------------------------------------------------------------------------

  describe "search_user_conversations/3" do
    setup do
      user_id = Ecto.UUID.generate()
      other_user_id = Ecto.UUID.generate()
      stranger_id = Ecto.UUID.generate()

      {:ok, group_conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Project Alpha"},
          is_active: true
        })

      {:ok, direct_conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(group_conv.id, user_id)
      {:ok, _} = Conversations.add_conversation_member(direct_conv.id, user_id)
      {:ok, _} = Conversations.add_conversation_member(direct_conv.id, other_user_id)

      %{
        user_id: user_id,
        other_user_id: other_user_id,
        stranger_id: stranger_id,
        group_conv: group_conv,
        direct_conv: direct_conv
      }
    end

    test "finds conversation by group name (partial match)", %{
      user_id: user_id,
      group_conv: group_conv
    } do
      results = Conversations.search_user_conversations(user_id, "Alpha")
      ids = Enum.map(results, & &1.id)
      assert group_conv.id in ids
    end

    test "finds conversation by participant user_id (exact match)", %{
      user_id: user_id,
      other_user_id: other_user_id,
      direct_conv: direct_conv
    } do
      results = Conversations.search_user_conversations(user_id, other_user_id)
      ids = Enum.map(results, & &1.id)
      assert direct_conv.id in ids
    end

    test "does not return conversations the user is not a member of", %{
      stranger_id: stranger_id
    } do
      other_id = Ecto.UUID.generate()

      {:ok, other_conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Secret Chat"},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(other_conv.id, stranger_id)

      results = Conversations.search_user_conversations(other_id, "Secret")
      assert results == []
    end

    test "returns empty list when no matches", %{user_id: user_id} do
      results = Conversations.search_user_conversations(user_id, "xyznonexistent")
      assert results == []
    end

    test "respects limit option", %{user_id: user_id} do
      # Create extra matching conversations
      for i <- 1..5 do
        {:ok, c} =
          Conversations.create_conversation(%{
            type: "group",
            metadata: %{"name" => "Team #{i}"},
            is_active: true
          })

        {:ok, _} = Conversations.add_conversation_member(c.id, user_id)
      end

      results = Conversations.search_user_conversations(user_id, "Team", limit: 3)
      assert length(results) <= 3
    end
  end
end
