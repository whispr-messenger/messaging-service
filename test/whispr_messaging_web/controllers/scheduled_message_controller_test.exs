defmodule WhisprMessagingWeb.ScheduledMessageControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  defp unique_client_random do
    rem(System.system_time(:microsecond) + :rand.uniform(10_000), 2_147_483_647)
  end

  defp future_iso(seconds_ahead \\ 3600) do
    DateTime.utc_now()
    |> DateTime.add(seconds_ahead, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp past_iso(seconds_ago \\ 60) do
    DateTime.utc_now()
    |> DateTime.add(-seconds_ago, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

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

  describe "POST /messages/scheduled" do
    test "schedules a message with a future scheduled_at", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "hi later",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })
        |> json_response(201)

      assert response["data"]["conversationId"] == ctx.conversation.id
      assert response["data"]["senderId"] == ctx.user_id
      assert response["data"]["status"] == "pending"
    end

    test "returns 422 for a past scheduled_at", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "in the past",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => past_iso()
        })

      assert conn.status in [400, 422]
    end

    test "returns 401 without auth header", ctx do
      response =
        build_conn()
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "hi",
          "scheduled_at" => future_iso()
        })
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when sender is not a member", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "hi",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 when the conversation does not exist", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => missing,
          "content" => "hi",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })
        |> json_response(404)

      assert response["error"] == "Conversation not found"
    end
  end

  describe "GET /messages/scheduled" do
    test "lists scheduled messages of the current user", ctx do
      {:ok, _sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "future hi",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/scheduled")
        |> json_response(200)

      assert is_list(response["data"])
      refute Enum.empty?(response["data"])
      assert response["meta"]["count"] == length(response["data"])
    end

    test "returns 401 without auth header" do
      response =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/scheduled")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end
  end

  describe "PATCH /messages/scheduled/:id" do
    test "updates a pending scheduled message's content", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{
          "content" => "v2-updated"
        })
        |> json_response(200)

      assert response["data"]["content"] == "v2-updated"
    end

    test "returns 401 without auth header", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{"content" => "x"})
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 403 when another user tries to update", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{"content" => "x"})
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 404 for an unknown id", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{missing}", %{"content" => "x"})
        |> json_response(404)

      assert response["error"] == "Scheduled message not found"
    end

    test "supports a nested scheduled_message body", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{
          "scheduled_message" => %{"content" => "nested-update"}
        })
        |> json_response(200)

      assert response["data"]["content"] == "nested-update"
    end
  end

  describe "POST /messages/scheduled — nested body" do
    test "supports the scheduled_message wrapper", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "scheduled_message" => %{
            "conversation_id" => ctx.conversation.id,
            "content" => "wrapped",
            "message_type" => "text",
            "client_random" => unique_client_random(),
            "scheduled_at" => future_iso()
          }
        })
        |> json_response(201)

      assert response["data"]["content"] == "wrapped"
    end
  end

  describe "DELETE /messages/scheduled/:id" do
    test "cancels the user's own pending scheduled message", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/scheduled/#{sm.id}")
        |> json_response(200)

      assert response["data"]["id"] == sm.id
      assert response["data"]["status"] == "cancelled"
    end

    test "returns 401 without auth header", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/scheduled/#{sm.id}")
        |> json_response(401)

      assert response["error"] == "Unauthorized"
    end

    test "returns 404 for unknown id", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/scheduled/#{missing}")
        |> json_response(404)

      assert response["error"] == "Scheduled message not found"
    end

    test "returns 403 when trying to cancel another user's message", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          "conversation_id" => ctx.conversation.id,
          "sender_id" => ctx.user_id,
          "content" => "v1",
          "message_type" => "text",
          "client_random" => unique_client_random(),
          "scheduled_at" => future_iso()
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.outsider_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/scheduled/#{sm.id}")
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end
  end
end
