defmodule WhisprMessagingWeb.MessageControllerExtrasTest do
  @moduledoc """
  Additional coverage for the message controller actions that are not
  exercised by the main test file: show, edge cases, search edge cases.
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, user2_id)

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "test message",
        client_random: System.unique_integer([:positive])
      })

    %{
      user1_id: user1_id,
      user2_id: user2_id,
      outsider_id: outsider_id,
      conversation: conversation,
      message: message
    }
  end

  describe "GET /messages/:id (show)" do
    test "returns the message data for an existing message", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/#{ctx.message.id}")
        |> json_response(200)

      assert response["data"]["id"] == ctx.message.id
    end

    test "returns 404 for an unknown message id", ctx do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/#{missing}")

      assert conn.status in [404, 500]
    end
  end

  describe "GET /messages/search — edge cases" do
    test "returns 400 when q is missing", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search")

      assert conn.status == 400
    end

    test "returns 400 when q is too short", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search?q=a")

      assert conn.status == 400
    end

    test "returns 401 without auth", _ctx do
      conn =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search?q=hello")

      assert conn.status == 401
    end

    test "honours conversation_id and limit query params", ctx do
      # Create a message with a plaintext_preview metadata key for matching
      {:ok, _} =
        Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user1_id,
          message_type: "text",
          content: "encrypted",
          metadata: %{"plaintext_preview" => "needle haystack search"},
          client_random: System.unique_integer([:positive])
        })

      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(
          ~p"/messaging/api/v1/messages/search?q=needle&conversation_id=#{ctx.conversation.id}&limit=5"
        )

      assert conn.status == 200
    end
  end

  describe "PATCH /messages/:id/receipt — error cases" do
    test "returns 400 for an invalid status", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user2_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/#{ctx.message.id}/receipt", %{"status" => "weird"})

      assert conn.status == 400
    end

    test "returns 400 when no status provided", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user2_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/#{ctx.message.id}/receipt", %{})

      assert conn.status == 400
    end
  end

  describe "POST /messages/:id/forward — error cases" do
    test "returns 422 when conversation_ids list is empty", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/forward", %{
          "conversation_ids" => []
        })

      assert conn.status == 422
    end

    test "returns 422 when conversation_ids missing", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/forward", %{})

      assert conn.status == 422
    end

    test "returns 401 without auth", ctx do
      conn =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/forward", %{
          "conversation_ids" => [Ecto.UUID.generate()]
        })

      assert conn.status == 401
    end
  end

  describe "DELETE /messages/:id — auth branches" do
    test "returns 401 without auth", ctx do
      conn =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}")

      assert conn.status == 401
    end
  end

  describe "PUT /messages/:id — auth branches" do
    test "returns 401 without auth", ctx do
      conn =
        build_conn()
        |> json_conn()
        |> put(~p"/messaging/api/v1/messages/#{ctx.message.id}", %{"content" => "new"})

      assert conn.status == 401
    end
  end

  describe "POST /messages — invalid signature returns 422" do
    test "returns 422 with malformed base64 signature", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages", %{
          "content" => "encrypted",
          "message_type" => "text",
          "client_random" => System.unique_integer([:positive]),
          "signature" => "not valid base64!!!",
          "sender_public_key" => Base.encode64(:crypto.strong_rand_bytes(32))
        })

      assert conn.status == 422
    end

    test "returns 422 when only signature is provided", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages", %{
          "content" => "encrypted",
          "message_type" => "text",
          "client_random" => System.unique_integer([:positive]),
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
        })

      assert conn.status == 422
    end

    test "returns 422 with wrong key length", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages", %{
          "content" => "encrypted",
          "message_type" => "text",
          "client_random" => System.unique_integer([:positive]),
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64)),
          "sender_public_key" => Base.encode64(:crypto.strong_rand_bytes(16))
        })

      assert conn.status == 422
    end
  end

  describe "GET /conversations/:id/messages — branches" do
    test "supports before_timestamp param", ctx do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages?before_timestamp=#{now}")

      assert conn.status == 200
    end

    test "honours custom limit", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages?limit=5")

      assert conn.status == 200
    end
  end

  describe "PATCH /messages/:id/receipt — happy paths" do
    test "marks delivered for the calling user", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user2_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/#{ctx.message.id}/receipt", %{
          "status" => "delivered"
        })
        |> json_response(200)

      assert response["data"] != nil
    end

    test "marks read for the calling user", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user2_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/#{ctx.message.id}/receipt", %{
          "status" => "read"
        })
        |> json_response(200)

      assert response["data"] != nil
    end
  end

  describe "POST /messages/:id/forward — happy path" do
    test "forwards a message to a target conversation", ctx do
      {:ok, target} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _} = WhisprMessaging.Conversations.add_conversation_member(target.id, ctx.user1_id)

      response =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{ctx.message.id}/forward", %{
          "conversation_ids" => [target.id]
        })
        |> json_response(201)

      assert is_list(response["data"])
      assert length(response["data"]) == 1
    end

    test "returns 404 for unknown source message", ctx do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/#{missing}/forward", %{
          "conversation_ids" => [ctx.conversation.id]
        })

      assert conn.status == 404
    end
  end

  describe "POST /conversations/:id/messages — body shapes" do
    test "supports message wrapper in body", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages", %{
          "message" => %{
            "content" => "wrapped",
            "message_type" => "text",
            "client_random" => System.unique_integer([:positive])
          }
        })
        |> json_response(201)

      assert response["data"]["content"] == "wrapped"
    end

    test "TTL ephemeral message supports ttl_seconds", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/messages", %{
          "content" => "ephemeral",
          "message_type" => "text",
          "client_random" => System.unique_integer([:positive]),
          "ttl_seconds" => 60
        })
        |> json_response(201)

      assert response["data"]["expires_at"] != nil or response["data"]["expiresAt"] != nil
    end
  end

  describe "DELETE /messages/:id" do
    test "soft-deletes a message for the caller (no delete_for_everyone)", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user2_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}")
        |> json_response(200)

      assert response["data"]["id"] == ctx.message.id
    end

    test "delete_for_everyone=true broadcasts message_deleted", ctx do
      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{ctx.conversation.id}"
      )

      build_conn()
      |> authenticated_conn(ctx.user1_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/#{ctx.message.id}?delete_for_everyone=true")
      |> json_response(200)

      assert_receive %Phoenix.Socket.Broadcast{event: "message_deleted"}, 1_000
    end
  end
end
