defmodule WhisprMessagingWeb.DraftControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  setup do
    user_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _m} = Conversations.add_conversation_member(conversation.id, user_id)

    %{
      user_id: user_id,
      outsider_id: outsider_id,
      conversation: conversation
    }
  end

  describe "POST /messages/drafts" do
    test "creates a draft for a conversation member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "draft body",
          "metadata" => %{"tag" => "demo"}
        })
        |> json_response(200)

      assert response["data"]["conversationId"] == ctx.conversation.id
      assert response["data"]["userId"] == ctx.user_id
      assert response["data"]["content"] == "draft body"
    end

    test "upserts: a second POST replaces the existing draft (single draft per user/conv)", ctx do
      conn = build_conn() |> authenticated_conn(ctx.user_id) |> json_conn()

      conn
      |> post(~p"/messaging/api/v1/messages/drafts", %{
        "conversation_id" => ctx.conversation.id,
        "content" => "v1"
      })
      |> json_response(200)

      r2 =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "v2"
        })
        |> json_response(200)

      assert r2["data"]["content"] == "v2"

      # Only one draft is kept
      assert {:ok, draft} = Messages.get_draft(ctx.conversation.id, ctx.user_id)
      assert draft.content == "v2"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "hello"
        })
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when the user is not a member of the conversation", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "hello"
        })
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for an unknown conversation", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => missing,
          "content" => "hello"
        })
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "GET /conversations/:id/drafts" do
    test "returns the user's draft for the conversation", ctx do
      {:ok, _draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "stored", %{})

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
        |> json_response(200)

      assert response["data"]["content"] == "stored"
    end

    test "returns 404 when no draft exists yet", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
        |> json_response(404)

      assert response["error"] == "No draft found"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when user is not a member of the conversation", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for unknown conversation", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{missing}/drafts")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "DELETE /messages/drafts/:id" do
    test "deletes the user's own draft", ctx do
      {:ok, draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "doomed", %{})

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/drafts/#{draft.id}")
        |> json_response(200)

      assert response["data"]["deleted"] == true
      assert response["data"]["id"] == draft.id
    end

    test "returns 401 without auth header", ctx do
      {:ok, draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "x", %{})

      response =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/drafts/#{draft.id}")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 for unknown draft id", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/drafts/#{missing}")
        |> json_response(404)

      assert response["error"] == "Draft not found"
    end

    test "returns 403 when trying to delete another user's draft", ctx do
      {:ok, draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "mine", %{})

      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/drafts/#{draft.id}")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end
  end

  describe "POST /messages/drafts — nested draft body" do
    test "supports the draft wrapper", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "draft" => %{
            "conversation_id" => ctx.conversation.id,
            "content" => "wrapped-body",
            "metadata" => %{"x" => 1}
          }
        })
        |> json_response(200)

      assert response["data"]["content"] == "wrapped-body"
    end
  end
end
