defmodule WhisprMessagingWeb.MessageControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    # Create test users
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    # Create test conversation
    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    # Add members
    {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

    %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    }
  end

  describe "GET /api/v1/conversations/:id/messages" do
    test "lists messages for a conversation", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create test messages
      for i <- 1..3 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "message_#{i}",
          client_random: i
        })
      end

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(200)

      assert response["data"] != nil
      assert length(response["data"]) == 3
    end

    test "returns empty list when no messages exist", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(200)

      assert response["data"] == []
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/api/v1/conversations/#{fake_id}/messages")
        |> json_response(404)

      assert response["error"] in ["Conversation not found", "Resource not found"]
    end

    test "returns 403 when user is not a member", %{conversation: conversation} do
      unauthorized_user = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(unauthorized_user)
        |> json_conn()

      response =
        get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "supports pagination with limit parameter", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create 10 messages
      for i <- 1..10 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "message_#{i}",
          client_random: i + 1000
        })
      end

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/api/v1/conversations/#{conversation.id}/messages?limit=5")
        |> json_response(200)

      assert length(response["data"]) <= 5
    end
  end

  describe "POST /api/v1/conversations/:id/messages" do
    test "creates a new message", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      message_attrs = %{
        "content" => "encrypted_content",
        "message_type" => "text",
        "client_random" => 12_345,
        "metadata" => %{"test" => true},
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["content"] == "encrypted_content"
      assert response["data"]["message_type"] == "text"
      assert response["data"]["sender_id"] == user1_id
      assert response["data"]["conversation_id"] == conversation.id
    end

    test "returns 422 with invalid attributes", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      invalid_attrs = %{
        "content" => "",
        "message_type" => "invalid_type",
        "client_random" => nil,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/api/v1/conversations/#{conversation.id}/messages",
          invalid_attrs
        )
        |> json_response(422)

      assert response["error"] == "Validation failed"
      assert response["details"] != nil
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 12_345,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/api/v1/conversations/#{fake_id}/messages",
          message_attrs
        )
        |> json_response(404)

      assert response["error"] in ["Conversation not found", "Resource not found"]
    end

    test "returns 403 when user is not a member", %{conversation: conversation} do
      unauthorized_user = Ecto.UUID.generate()

      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 12_345,
        "sender_id" => unauthorized_user
      }

      conn =
        build_conn()
        |> authenticated_conn(unauthorized_user)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "prevents duplicate client_random", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 99_999,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      # First message should succeed
      post(
        conn,
        ~p"/api/v1/conversations/#{conversation.id}/messages",
        message_attrs
      )
      |> json_response(201)

      # Second message with same client_random should fail
      response =
        post(
          conn,
          ~p"/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(422)

      assert response["error"] == "Validation failed"
      assert response["details"] != nil
    end
  end

  describe "PUT /api/v1/messages/:id" do
    setup %{conversation: conversation, user1_id: user1_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 54_321
        })

      %{message: message}
    end

    test "updates a message", %{message: message, user1_id: user1_id} do
      update_attrs = %{
        "content" => "updated_content",
        "metadata" => %{"edited" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          update_attrs
        )
        |> json_response(200)

      assert response["data"]["content"] == "updated_content"
      assert response["data"]["metadata"]["edited"] == true
      assert response["data"]["edited_at"] != nil
    end

    test "returns 404 for non-existent message", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      update_attrs = %{
        "content" => "new_content",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/api/v1/messages/#{fake_id}",
          update_attrs
        )
        |> json_response(404)

      # The actual error message from fallback controller is "Resource not found"
      # But we can accept either standard message
      assert response["error"] in ["Message not found", "Resource not found"]
    end

    test "returns 403 when trying to edit another user's message", %{
      message: message,
      user2_id: user2_id
    } do
      update_attrs = %{
        "content" => "hacked_content",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          update_attrs
        )
        # FallbackController might be rendering 403 correctly now
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 422 with invalid content", %{message: message, user1_id: user1_id} do
      # Update with invalid attributes
      update_attrs = %{
        "content" => nil,
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          update_attrs
        )
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "DELETE /api/v1/messages/:id" do
    setup %{conversation: conversation, user1_id: user1_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "content_to_delete",
          client_random: 77_777
        })

      %{message: message}
    end

    test "deletes a message", %{message: message, user1_id: user1_id} do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          delete_for_everyone: true
        )
        |> json_response(200)

      assert response["data"]["is_deleted"] == true
      assert response["data"]["delete_for_everyone"] == true
    end

    test "returns 404 for non-existent message", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/api/v1/messages/#{fake_id}",
          delete_for_everyone: false
        )
        |> json_response(404)

      assert response["error"] in ["Message not found", "Resource not found"]
    end

    test "returns 403 when trying to delete another user's message", %{
      message: message,
      user2_id: user2_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "soft deletes message without delete_for_everyone", %{
      message: message,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(200)

      assert response["data"]["is_deleted"] == true
      assert response["data"]["delete_for_everyone"] == false
    end
  end
end
