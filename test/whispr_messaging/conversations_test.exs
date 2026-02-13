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
end
