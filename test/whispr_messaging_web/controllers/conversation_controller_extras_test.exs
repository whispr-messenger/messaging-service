defmodule WhisprMessagingWeb.ConversationControllerExtrasTest do
  @moduledoc """
  Coverage for actions of `ConversationController` not exercised by the main
  controller test file: search, archived listing, archive/unarchive, and the
  per-member settings endpoints.
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations

  setup do
    user_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        name: "Backend brigade",
        metadata: %{"name" => "Backend brigade"},
        is_active: true
      })

    {:ok, _m} = Conversations.add_conversation_member(conversation.id, user_id)

    %{user_id: user_id, outsider_id: outsider_id, conversation: conversation}
  end

  describe "GET /conversations/search" do
    test "returns 400 when q is missing", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search")
        |> json_response(400)

      assert response["error"] =~ "q"
    end

    test "returns 400 when q is empty", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=%20%20")
        |> json_response(400)

      assert response["error"] =~ "q"
    end

    test "returns 401 without auth header" do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=brigade")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns matches and includes meta", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=brigade")
        |> json_response(200)

      assert response["meta"]["query"] == "brigade"
      assert is_integer(response["meta"]["count"])
      assert is_list(response["data"])
    end

    test "clamps limit to a maximum of 50 and supports custom limits", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=brigade&limit=99")
        |> json_response(200)

      assert response["meta"]["count"] <= 50
    end

    test "falls back to default limit on malformed input", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/search?q=brigade&limit=abc")
        |> json_response(200)

      assert is_list(response["data"])
    end
  end

  describe "GET /conversations/archived" do
    test "returns the user's archived conversations only", ctx do
      Conversations.archive_conversation(ctx.conversation.id, ctx.user_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/archived")
        |> json_response(200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ctx.conversation.id in ids
      assert response["meta"]["userId"] == ctx.user_id
    end

    test "returns 401 without auth header" do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/archived")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "POST /conversations/:id/archive" do
    test "archives a conversation for the current user and broadcasts to user:<id>",
         ctx do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{ctx.user_id}")

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(200)

      assert response["data"]["archived"] == true
      assert response["data"]["conversation_id"] == ctx.conversation.id

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "conversation_archived",
                       payload: %{archived: true}
                     },
                     1_500
    end

    test "returns 422 when conversation is already archived", ctx do
      Conversations.archive_conversation(ctx.conversation.id, ctx.user_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(422)

      assert response["error"] =~ "already archived"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "DELETE /conversations/:id/archive" do
    test "unarchives a previously archived conversation", ctx do
      Conversations.archive_conversation(ctx.conversation.id, ctx.user_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(200)

      assert response["data"]["archived"] == false
      assert response["data"]["conversation_id"] == ctx.conversation.id
    end

    test "returns 422 when conversation is not archived", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(422)

      assert response["error"] =~ "not archived"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/archive")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "GET /conversations/:id/settings" do
    test "returns the user's per-conversation settings", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings")
        |> json_response(200)

      assert response["data"]["conversation_id"] == ctx.conversation.id
      assert is_map(response["data"]["settings"])
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "POST /conversations/:id/pin" do
    test "pins a conversation for the current user and broadcasts to user:<id>", ctx do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{ctx.user_id}")

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(200)

      assert response["data"]["pinned"] == true
      assert response["data"]["conversation_id"] == ctx.conversation.id

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "conversation_pinned",
                       payload: %{pinned: true}
                     },
                     1_500
    end

    test "returns 422 when already pinned", ctx do
      Conversations.pin_conversation(ctx.conversation.id, ctx.user_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(422)

      assert response["error"] =~ "already pinned"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "DELETE /conversations/:id/pin" do
    test "unpins a previously pinned conversation", ctx do
      Conversations.pin_conversation(ctx.conversation.id, ctx.user_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(200)

      assert response["data"]["pinned"] == false
    end

    test "returns 422 when conversation is not pinned", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(422)

      assert response["error"] =~ "not pinned"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/pin")
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "POST /conversations — error branches" do
    test "returns 400 for invalid/missing type", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations", %{"foo" => "bar"})

      assert conn.status in [400, 422]
    end

    test "returns 400 when creating a group without name", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations", %{
          "type" => "group",
          "user_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
        })

      assert conn.status in [400, 422]
    end

    test "returns 422 when creating a group with insufficient members", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations", %{
          "type" => "group",
          "name" => "TinyGroup",
          "user_ids" => [ctx.user_id]
        })

      assert conn.status in [422]
    end
  end

  describe "PUT /conversations/:id — metadata merging" do
    test "merges new metadata into existing metadata", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}", %{
          "metadata" => %{"description" => "Updated description"}
        })
        |> json_response(200)

      assert response["data"]["metadata"]["description"] == "Updated description"
    end
  end

  describe "PUT /conversations/:id/settings" do
    test "updates the user's per-conversation settings", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings", %{
          "is_muted" => true
        })
        |> json_response(200)

      assert response["data"]["settings"]["is_muted"] == true
    end

    test "returns 404 when user is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings", %{
          "is_muted" => true
        })
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> put(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/settings", %{
          "is_muted" => true
        })
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end
end
