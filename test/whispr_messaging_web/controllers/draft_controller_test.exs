defmodule WhisprMessagingWeb.DraftControllerTest do
  @moduledoc """
  Controller tests for message drafts (POST /messages/drafts,
  GET /conversations/:id/drafts, DELETE /messages/drafts/:id).
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
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

    %{
      user_id: user_id,
      other_id: other_id,
      stranger_id: stranger_id,
      conversation: conversation
    }
  end

  describe "POST /messaging/api/v1/messages/drafts" do
    test "creates a draft for a conversation member", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "draft content",
          "metadata" => %{"foo" => "bar"}
        })
        |> json_response(200)

      assert body["data"]["conversationId"] == ctx.conversation.id
      assert body["data"]["userId"] == ctx.user_id
      assert body["data"]["content"] == "draft content"
    end

    test "supports the nested 'draft' wrapper key", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "draft" => %{
            "conversation_id" => ctx.conversation.id,
            "content" => "wrapped draft"
          }
        })
        |> json_response(200)

      assert body["data"]["content"] == "wrapped draft"
    end

    test "upserts and replaces an existing draft", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/drafts", %{
        "conversation_id" => ctx.conversation.id,
        "content" => "initial"
      })
      |> json_response(200)

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/drafts", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "updated"
        })
        |> json_response(200)

      assert body["data"]["content"] == "updated"

      assert {:ok, draft} = Messages.get_draft(ctx.conversation.id, ctx.user_id)
      assert draft.content == "updated"
    end

    test "rejects unknown conversations with 404", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/drafts", %{
        "conversation_id" => Ecto.UUID.generate(),
        "content" => "x"
      })
      |> json_response(404)
    end

    test "rejects non-members with 403", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/drafts", %{
        "conversation_id" => ctx.conversation.id,
        "content" => "x"
      })
      |> json_response(403)
    end
  end

  describe "GET /messaging/api/v1/conversations/:id/drafts" do
    test "returns the draft for the current user", ctx do
      {:ok, _} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "hello", %{})

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
        |> json_response(200)

      assert body["data"]["content"] == "hello"
      assert body["data"]["userId"] == ctx.user_id
    end

    test "returns 404 when no draft exists", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
      |> json_response(404)
    end

    test "returns 404 for unknown conversation", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{Ecto.UUID.generate()}/drafts")
      |> json_response(404)
    end

    test "returns 403 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/drafts")
      |> json_response(403)
    end
  end

  describe "DELETE /messaging/api/v1/messages/drafts/:id" do
    test "deletes the user's own draft", ctx do
      {:ok, draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "to delete", %{})

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/drafts/#{draft.id}")
        |> json_response(200)

      assert body["data"]["deleted"] == true
      assert body["data"]["id"] == draft.id

      assert {:error, :not_found} =
               Messages.get_draft(ctx.conversation.id, ctx.user_id)
    end

    test "returns 404 for unknown draft id", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/drafts/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end

    test "returns 403 when another user tries to delete a draft", ctx do
      {:ok, draft} = Messages.upsert_draft(ctx.conversation.id, ctx.user_id, "owned", %{})

      build_conn()
      |> authenticated_conn(ctx.other_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/drafts/#{draft.id}")
      |> json_response(403)
    end
  end
end
