defmodule WhisprMessagingWeb.PinControllerTest do
  @moduledoc """
  Controller tests for the message pin / unpin endpoints
  (POST /messages/:id/pin, DELETE /messages/:id/pin, GET /conversations/:id/pins).
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  setup do
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    stranger_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "pin tests"},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user_id,
        message_type: "text",
        content: "to-pin",
        client_random: System.unique_integer([:positive])
      })

    %{
      user_id: user_id,
      other_id: other_id,
      stranger_id: stranger_id,
      conversation: conversation,
      message: message
    }
  end

  describe "POST /messaging/api/v1/messages/:id/pin" do
    test "pins a message for a conversation member", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(201)

      assert body["data"]["messageId"] == ctx.message.id
      assert body["data"]["pinnedBy"] == ctx.user_id
    end

    test "returns 404 for unknown message id", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{Ecto.UUID.generate()}/pin")
      |> json_response(404)
    end

    test "returns 403 for a non-member", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
      |> json_response(403)
    end
  end

  describe "DELETE /messaging/api/v1/messages/:id/pin" do
    test "unpins a previously pinned message", ctx do
      {:ok, _} = Messages.pin_message(ctx.message.id, ctx.user_id)

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
        |> json_response(200)

      assert body["data"]["unpinned"] == true
      assert body["data"]["messageId"] == ctx.message.id
    end

    test "returns 404 when no pin exists", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
      |> json_response(404)
    end

    test "returns 403 for non-members", ctx do
      {:ok, _} = Messages.pin_message(ctx.message.id, ctx.user_id)

      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}/pin")
      |> json_response(403)
    end
  end

  describe "GET /messaging/api/v1/conversations/:id/pins" do
    test "lists pinned messages for a conversation member", ctx do
      {:ok, _} = Messages.pin_message(ctx.message.id, ctx.user_id)

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
        |> json_response(200)

      assert body["meta"]["count"] == 1
      assert body["meta"]["conversationId"] == ctx.conversation.id
      assert is_list(body["data"])
    end

    test "returns empty list when no pinned messages exist", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
        |> json_response(200)

      assert body["data"] == []
      assert body["meta"]["count"] == 0
    end

    test "returns 404 for unknown conversation id", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{Ecto.UUID.generate()}/pins")
      |> json_response(404)
    end

    test "returns 403 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pins")
      |> json_response(403)
    end
  end
end
