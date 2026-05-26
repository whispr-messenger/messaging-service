defmodule WhisprMessagingWeb.ScheduledMessageControllerTest do
  @moduledoc """
  Controller tests for the scheduled messages REST endpoints.
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
        metadata: %{"name" => "scheduled tests"},
        is_active: true,
        e2ee_enabled: false
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

  defp future_iso(seconds_from_now \\ 3600) do
    DateTime.utc_now()
    |> DateTime.add(seconds_from_now, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  describe "POST /messaging/api/v1/messages/scheduled" do
    test "creates a scheduled message for a conversation member", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/messages/scheduled", %{
          "conversation_id" => ctx.conversation.id,
          "content" => "later",
          "client_random" => System.unique_integer([:positive]),
          "scheduled_at" => future_iso()
        })
        |> json_response(201)

      assert body["data"]["status"] == "pending"
      assert body["data"]["conversationId"] == ctx.conversation.id
      assert body["data"]["senderId"] == ctx.user_id
    end

    test "404 when conversation does not exist", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/scheduled", %{
        "conversation_id" => Ecto.UUID.generate(),
        "content" => "x",
        "client_random" => System.unique_integer([:positive]),
        "scheduled_at" => future_iso()
      })
      |> json_response(404)
    end

    test "403 when user is not a member", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/scheduled", %{
        "conversation_id" => ctx.conversation.id,
        "content" => "x",
        "client_random" => System.unique_integer([:positive]),
        "scheduled_at" => future_iso()
      })
      |> json_response(403)
    end

    test "422 when scheduled_at is in the past", ctx do
      past =
        DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/messages/scheduled", %{
        "conversation_id" => ctx.conversation.id,
        "content" => "x",
        "client_random" => System.unique_integer([:positive]),
        "scheduled_at" => past
      })
      |> json_response(422)
    end
  end

  describe "GET /messaging/api/v1/messages/scheduled" do
    test "lists pending scheduled messages of the current user", ctx do
      {:ok, _} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "later1",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      {:ok, _} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "later2",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(7200, :second)
        })

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/scheduled")
        |> json_response(200)

      assert body["meta"]["count"] == 2
      assert length(body["data"]) == 2
    end

    test "returns empty list when user has no scheduled messages", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/scheduled")
        |> json_response(200)

      assert body["data"] == []
      assert body["meta"]["count"] == 0
    end
  end

  describe "DELETE /messaging/api/v1/messages/scheduled/:id" do
    test "cancels a pending scheduled message owned by the user", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "later",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> delete(~p"/messaging/api/v1/messages/scheduled/#{sm.id}")
        |> json_response(200)

      assert body["data"]["status"] == "cancelled"
    end

    test "404 for unknown scheduled message id", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/scheduled/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end

    test "403 when another user tries to cancel", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "later",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      build_conn()
      |> authenticated_conn(ctx.other_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/messages/scheduled/#{sm.id}")
      |> json_response(403)
    end
  end

  describe "PATCH /messaging/api/v1/messages/scheduled/:id" do
    test "updates content and scheduled_at of a pending scheduled message", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "old",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      body =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{
          "content" => "new content",
          "scheduled_at" => future_iso(7200)
        })
        |> json_response(200)

      assert body["data"]["content"] == "new content"
    end

    test "404 when scheduled message does not exist", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> patch(~p"/messaging/api/v1/messages/scheduled/#{Ecto.UUID.generate()}", %{
        "content" => "x"
      })
      |> json_response(404)
    end

    test "403 when another user tries to update", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "x",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      build_conn()
      |> authenticated_conn(ctx.other_id)
      |> json_conn()
      |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{"content" => "y"})
      |> json_response(403)
    end

    test "422 when trying to update an already cancelled scheduled message", ctx do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: "x",
          message_type: "text",
          client_random: System.unique_integer([:positive]),
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })

      {:ok, _} = Messages.cancel_scheduled_message(sm.id, ctx.user_id)

      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> patch(~p"/messaging/api/v1/messages/scheduled/#{sm.id}", %{"content" => "y"})
      |> json_response(422)
    end
  end
end
