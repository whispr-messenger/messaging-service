defmodule WhisprMessagingWeb.ConversationControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()
    user3_id = Ecto.UUID.generate()

    %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    }
  end

  describe "GET /api/v1/conversations" do
    test "lists all conversations for a user", %{user1_id: user1_id, user2_id: user2_id} do
      # Create conversations
      {:ok, conversation1} =
        Conversations.create_conversation(%{
          type: "direct",
          is_active: true
        })

      {:ok, conversation2} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Test Group",
          is_active: true
        })

      # Add user1 as member
      Conversations.add_conversation_member(conversation1.id, user1_id)
      Conversations.add_conversation_member(conversation2.id, user1_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :index))
        |> json_response(200)

      assert response["data"] != nil
      assert length(response["data"]) >= 2
    end

    test "returns empty list when user has no conversations", %{user1_id: user1_id} do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :index))
        |> json_response(200)

      assert response["data"] == []
    end

    test "supports filtering by type", %{user1_id: user1_id} do
      # Create direct and group conversations
      {:ok, direct_conv} =
        Conversations.create_conversation(%{
          type: "direct",
          is_active: true
        })

      {:ok, group_conv} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Team Group",
          is_active: true
        })

      Conversations.add_conversation_member(direct_conv.id, user1_id)
      Conversations.add_conversation_member(group_conv.id, user1_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :index), type: "group")
        |> json_response(200)

      assert Enum.all?(response["data"], fn c -> c["type"] == "group" end)
    end

    test "requires authentication" do
      conn =
        build_conn()
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :index))
        |> json_response(401)

      assert response["error"] != nil
    end
  end

  describe "POST /api/v1/conversations (direct)" do
    test "creates a direct conversation with two users", %{user1_id: user1_id, user2_id: user2_id} do
      attrs = %{
        "type" => "direct",
        "other_user_id" => user2_id,
        "metadata" => %{"test" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["type"] == "direct"
      assert response["data"]["is_active"] == true
    end

    test "returns error when trying to create conversation with self", %{user1_id: user1_id} do
      attrs = %{
        "type" => "direct",
        "other_user_id" => user1_id,
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end

    test "returns 400 when missing other_user_id", %{user1_id: user1_id} do
      attrs = %{
        "type" => "direct",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(400)

      assert response["error"] != nil
    end
  end

  describe "POST /api/v1/conversations (group)" do
    test "creates a group conversation with multiple users", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      attrs = %{
        "type" => "group",
        "name" => "Test Group Chat",
        "member_ids" => [user2_id, user3_id],
        "metadata" => %{"description" => "Test group"}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["type"] == "group"
      assert response["data"]["name"] == "Test Group Chat"
      assert response["data"]["is_active"] == true
    end

    test "returns 422 when group name is missing", %{user1_id: user1_id, user2_id: user2_id} do
      attrs = %{
        "type" => "group",
        "member_ids" => [user2_id],
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end

    test "returns 422 when group has too few members", %{user1_id: user1_id} do
      attrs = %{
        "type" => "group",
        "name" => "Solo Group",
        "member_ids" => [],
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(conn, Routes.api_v1_conversation_path(conn, :create), attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "GET /api/v1/conversations/:id" do
    test "retrieves a conversation by ID", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :show, conversation.id))
        |> json_response(200)

      assert response["data"]["id"] == conversation.id
      assert response["data"]["type"] == "direct"
      assert response["data"]["is_active"] == true
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :show, fake_id))
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :show, conversation.id))
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "includes member list in response", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, Routes.api_v1_conversation_path(conn, :show, conversation.id))
        |> json_response(200)

      assert response["data"]["members"] != nil
      assert length(response["data"]["members"]) == 2
    end
  end

  describe "PUT /api/v1/conversations/:id" do
    test "updates a group conversation name", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Old Name",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      update_attrs = %{
        "name" => "New Group Name",
        "metadata" => %{"updated" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, Routes.api_v1_conversation_path(conn, :update, conversation.id), update_attrs)
        |> json_response(200)

      assert response["data"]["name"] == "New Group Name"
      assert response["data"]["metadata"]["updated"] == true
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      update_attrs = %{
        "name" => "Updated Name",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, Routes.api_v1_conversation_path(conn, :update, fake_id), update_attrs)
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Original Name",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id)

      update_attrs = %{
        "name" => "Hacked Name",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, Routes.api_v1_conversation_path(conn, :update, conversation.id), update_attrs)
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "returns 422 with invalid attributes", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Original Name",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      update_attrs = %{
        "name" => "",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(conn, Routes.api_v1_conversation_path(conn, :update, conversation.id), update_attrs)
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "DELETE /api/v1/conversations/:id" do
    test "deactivates a conversation", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "To Delete",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, Routes.api_v1_conversation_path(conn, :delete, conversation.id))
        |> json_response(200)

      assert response["data"]["is_active"] == false
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, Routes.api_v1_conversation_path(conn, :delete, fake_id))
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 403 when user is not a member", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Not Mine",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(conn, Routes.api_v1_conversation_path(conn, :delete, conversation.id))
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "POST /api/v1/conversations/:id/members" do
    test "adds a member to a group conversation", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Team",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      add_attrs = %{
        "user_id" => user3_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          Routes.api_v1_conversation_member_path(conn, :add_member, conversation.id),
          add_attrs
        )
        |> json_response(201)

      assert response["data"]["user_id"] == user3_id
      assert response["data"]["is_active"] == true
    end

    test "returns 403 for non-admin trying to add member", %{
      user1_id: user1_id,
      user2_id: user2_id,
      user3_id: user3_id
    } do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Team",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      add_attrs = %{
        "user_id" => user3_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(
          conn,
          Routes.api_v1_conversation_member_path(conn, :add_member, conversation.id),
          add_attrs
        )
        |> json_response(403)

      assert response["error"] != nil
    end
  end

  describe "DELETE /api/v1/conversations/:id/members/:user_id" do
    test "removes a member from conversation", %{user1_id: user1_id, user2_id: user2_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Team",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)
      Conversations.add_conversation_member(conversation.id, user2_id)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          Routes.api_v1_conversation_member_path(conn, :remove_member, conversation.id, user2_id)
        )
        |> json_response(200)

      assert response["data"]["is_active"] == false
    end

    test "returns 404 for non-existent member", %{user1_id: user1_id} do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          name: "Team",
          is_active: true
        })

      Conversations.add_conversation_member(conversation.id, user1_id)

      fake_user_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          Routes.api_v1_conversation_member_path(
            conn,
            :remove_member,
            conversation.id,
            fake_user_id
          )
        )
        |> json_response(404)

      assert response["error"] != nil
    end
  end
end
