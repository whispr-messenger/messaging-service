defmodule WhisprMessaging.ConversationsTest do
  use WhisprMessaging.DataCase

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember}

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
        name: "Team Chat",
        metadata: %{},
        is_active: true
      }

      assert {:ok, %Conversation{} = conversation} = Conversations.create_conversation(attrs)
      assert conversation.type == "group"
      assert conversation.name == "Team Chat"
    end
  end

  describe "get_conversation/1" do
    setup do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "direct",
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
    end
  end

  describe "update_conversation/2" do
    setup do
      {:ok, conversation} = Conversations.create_conversation(%{
        type: "group",
        name: "Old Name",
        is_active: true
      })
      %{conversation: conversation}
    end

    test "updates conversation name", %{conversation: conversation} do
      assert {:ok, updated} = Conversations.update_conversation(conversation, %{name: "New Name"})
      assert updated.name == "New Name"
    end
  end
end
