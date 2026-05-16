defmodule WhisprMessagingWeb.PinControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.{Conversations, Messages}

  defp unique_client_random do
    rem(System.system_time(:microsecond) + :rand.uniform(10_000), 2_147_483_647)
  end

  defp setup_conversation_and_message(content \\ "to be pinned") do
    user_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _m} = Conversations.add_conversation_member(conversation.id, user_id)

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user_id,
        message_type: "text",
        content: content,
        client_random: unique_client_random()
      })

    {user_id, outsider_id, conversation, message}
  end

  setup do
    {user_id, outsider_id, conversation, message} = setup_conversation_and_message()

    %{
      user_id: user_id,
      outsider_id: outsider_id,
      conversation: conversation,
      message: message
    }
  end

  describe "POST /messages/:id/pin" do
    test "pins a message for a member of the conversation", ctx do
      conn = build_conn() |> authenticated_conn(ctx.user_id) |> json_conn()

      response =
        conn
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(201)

      assert response["data"]["messageId"] == ctx.message.id
      assert response["data"]["conversationId"] == ctx.conversation.id
      assert response["data"]["pinnedBy"] == ctx.user_id
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when the user is not a member of the conversation", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for an unknown message id", ctx do
      missing_id = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{missing_id}/pin")
        |> json_response(404)

      assert response["error"] == "Message not found"
    end
  end

  describe "DELETE /messages/:id/pin" do
    test "unpins a message previously pinned by a member", ctx do
      # Pin first
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
      |> json_response(201)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(200)

      assert response["data"]["messageId"] == ctx.message.id
      assert response["data"]["unpinned"] == true
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when the user is not a member of the conversation", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for unknown message id", ctx do
      missing_id = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{missing_id}/pin")
        |> json_response(404)

      assert is_binary(response["error"])
    end
  end

  describe "GET /conversations/:id/pins" do
    test "lists pinned messages for a member", ctx do
      # Pin two messages
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")

      {:ok, other_message} =
        Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          message_type: "text",
          content: "second pin",
          client_random: unique_client_random()
        })

      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{other_message.id}/pin")

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
        |> json_response(200)

      assert length(response["data"]) == 2
      assert response["meta"]["count"] == 2
      assert response["meta"]["conversationId"] == ctx.conversation.id
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when the user is not a member of the conversation", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for unknown conversation id", ctx do
      missing_id = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{missing_id}/pins")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end
end
