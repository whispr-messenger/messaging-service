defmodule WhisprMessaging.ConversationsTest do
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations

  describe "create_conversation/1" do
    test "creates a direct conversation" do
      attrs = %{type: "direct", metadata: %{}, is_active: true}
      assert {:ok, conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "direct"
      assert conversation.is_active == true
    end

    test "creates a group conversation" do
      attrs = %{type: "group", metadata: %{"name" => "Test Group"}, is_active: true}
      assert {:ok, conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "group"
      assert conversation.metadata["name"] == "Test Group"
    end
  end

  describe "add_conversation_member/2" do
    test "adds a member to conversation" do
      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      user_id = Ecto.UUID.generate()
      assert {:ok, member} = Conversations.add_conversation_member(conversation.id, user_id)
      assert member.user_id == user_id
      assert member.conversation_id == conversation.id
    end
  end

  describe "list_user_conversations/2" do
    test "returns conversations for a user" do
      user_id = Ecto.UUID.generate()

      {:ok, conv1} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, conv2} =
        Conversations.create_conversation(%{type: "group", metadata: %{"name" => "Test Group"}, is_active: true})

      Conversations.add_conversation_member(conv1.id, user_id)
      Conversations.add_conversation_member(conv2.id, user_id)

      conversations = Conversations.list_user_conversations(user_id, 50)
      assert length(conversations) == 2
    end
  end

  describe "get_conversation/1" do
    test "returns existing conversation" do
      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      assert {:ok, found} = Conversations.get_conversation(conversation.id)
      assert found.id == conversation.id
    end

    test "returns error for non-existent conversation" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Conversations.get_conversation(fake_id)
    end
  end

  describe "deactivate_conversation/1" do
    test "deactivates an active conversation" do
      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      assert {:ok, deactivated} = Conversations.deactivate_conversation(conversation)
      assert deactivated.is_active == false
    end
  end

  describe "remove_conversation_member/2" do
    test "removes a member from conversation" do
      user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{type: "group", metadata: %{"name" => "Test Group"}, is_active: true})

      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)
      assert {:ok, removed} = Conversations.remove_conversation_member(conversation.id, user_id)
      assert removed.is_active == false
    end
  end

  describe "update_conversation/2" do
    test "updates conversation metadata" do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Old"},
          is_active: true
        })

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
      assert {:ok, _} =
               Conversations.update_conversation_member_settings(c.id, user_id, %{
                 "role" => "admin"
               })

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
  # Pin / Unpin tests (WHISPR-465)
  # ---------------------------------------------------------------------------

  describe "pin_conversation/2" do
    setup do
      user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "pins a conversation successfully", %{conversation: c, user_id: user_id} do
      assert {:ok, member} = Conversations.pin_conversation(c.id, user_id)
      assert member.settings["is_pinned"] == true
    end

    test "returns :already_pinned when already pinned", %{conversation: c, user_id: user_id} do
      {:ok, _} = Conversations.pin_conversation(c.id, user_id)
      assert {:error, :already_pinned} = Conversations.pin_conversation(c.id, user_id)
    end

    test "returns :not_member when user is not a member", %{conversation: c} do
      stranger = Ecto.UUID.generate()
      assert {:error, :not_member} = Conversations.pin_conversation(c.id, stranger)
    end

    test "returns :pin_limit_reached when 5 conversations are already pinned", %{
      user_id: user_id
    } do
      for _i <- 1..5 do
        {:ok, conv} =
          Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

        {:ok, _} = Conversations.add_conversation_member(conv.id, user_id)
        {:ok, _} = Conversations.pin_conversation(conv.id, user_id)
      end

      {:ok, sixth} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _} = Conversations.add_conversation_member(sixth.id, user_id)

      assert {:error, :pin_limit_reached} = Conversations.pin_conversation(sixth.id, user_id)
    end
  end

  describe "unpin_conversation/2" do
    setup do
      user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)
      {:ok, _} = Conversations.pin_conversation(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "unpins a conversation successfully", %{conversation: c, user_id: user_id} do
      assert {:ok, member} = Conversations.unpin_conversation(c.id, user_id)
      assert member.settings["is_pinned"] == false
    end

    test "returns :not_pinned when conversation is not pinned", %{
      conversation: _c,
      user_id: user_id
    } do
      {:ok, other} =
        Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

      {:ok, _} = Conversations.add_conversation_member(other.id, user_id)

      assert {:error, :not_pinned} = Conversations.unpin_conversation(other.id, user_id)
    end

    test "returns :not_member when user is not a member", %{conversation: c} do
      stranger = Ecto.UUID.generate()
      assert {:error, :not_member} = Conversations.unpin_conversation(c.id, stranger)
    end
  end
end
