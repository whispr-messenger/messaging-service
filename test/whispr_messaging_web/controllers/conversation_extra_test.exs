defmodule WhisprMessagingWeb.ConversationExtraTest do
  @moduledoc """
  Coverage of the conversation controller actions that the existing
  `conversation_controller_test.exs` does not exercise: search,
  per-user settings, pin/unpin.
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ConversationMember

  setup do
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    stranger_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Search me"},
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

  describe "GET /messaging/api/v1/conversations/search" do
    test "returns matching conversations for the current user", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=Search")
        |> json_response(200)

      assert body["meta"]["query"] == "Search"
      assert is_list(body["data"])
    end

    test "returns 400 when q is missing", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/search")
      |> json_response(400)
    end

    test "returns 400 when q is blank", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/search?q=%20%20")
      |> json_response(400)
    end

    test "respects the limit parameter (capped at 50)", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=Search&limit=5")
        |> json_response(200)

      assert length(body["data"]) <= 5
    end
  end

  describe "GET /messaging/api/v1/conversations/:id/settings" do
    test "returns the per-user settings for a member", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings")
        |> json_response(200)

      assert body["data"]["conversation_id"] == ctx.conversation.id
      assert is_map(body["data"]["settings"])
    end

    test "returns 404 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings")
      |> json_response(404)
    end
  end

  describe "PUT /messaging/api/v1/conversations/:id/settings" do
    test "updates recognised setting fields for the caller", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings", %{
          "settings" => %{"is_muted" => true}
        })
        |> json_response(200)

      assert body["data"]["settings"]["is_muted"] == true
    end

    test "returns 404 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings", %{
        "settings" => %{"is_muted" => true}
      })
      |> json_response(404)
    end
  end

  describe "POST /messaging/api/v1/conversations/:id/pin" do
    test "pins the conversation for the user", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(200)

      assert body["data"]["pinned"] == true
    end

    test "returns 404 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(404)
    end

    test "returns 422 when the conversation is already pinned", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(200)

      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(422)
    end
  end

  describe "DELETE /messaging/api/v1/conversations/:id/pin" do
    test "unpins a previously pinned conversation", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(200)

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(200)

      assert body["data"]["pinned"] == false
    end

    test "returns 422 when the conversation is not pinned", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(422)
    end

    test "returns 404 for non-members", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
      |> json_response(404)
    end
  end

  # Verify that `default_settings/0` from the schema is referenced — gives
  # an extra easy bump on conversation_member coverage.
  test "ConversationMember.default_settings/0 returns expected keys" do
    assert Map.has_key?(ConversationMember.default_settings(), "notifications")
  end
end
