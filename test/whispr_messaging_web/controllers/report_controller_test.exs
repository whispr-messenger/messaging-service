defmodule WhisprMessagingWeb.ReportControllerTest do
  use WhisprMessagingWeb.ConnCase, async: false

  alias WhisprMessaging.Conversations

  setup do
    reporter_id = Ecto.UUID.generate()
    reported_user_id = Ecto.UUID.generate()
    admin_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{type: "direct", metadata: %{}, is_active: true})

    Conversations.add_conversation_member(conversation.id, reporter_id)
    Conversations.add_conversation_member(conversation.id, reported_user_id)

    {:ok, message} =
      WhisprMessaging.Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: reported_user_id,
        message_type: "text",
        content: "offensive content",
        client_random: System.unique_integer([:positive])
      })

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      admin_id: admin_id,
      conversation: conversation,
      message: message
    }
  end

  describe "POST /messaging/api/v1/reports" do
    test "creates a report successfully", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      body = %{
        "reported_user_id" => ctx.reported_user_id,
        "conversation_id" => ctx.conversation.id,
        "message_id" => ctx.message.id,
        "category" => "offensive",
        "description" => "This is offensive"
      }

      response =
        post(conn, ~p"/messaging/api/v1/reports", body)
        |> json_response(201)

      assert response["data"]["category"] == "offensive"
      assert response["data"]["status"] == "pending"
      assert response["data"]["reporter_id"] == ctx.reporter_id
    end

    test "rejects self-report", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      body = %{
        "reported_user_id" => ctx.reporter_id,
        "category" => "spam"
      }

      post(conn, ~p"/messaging/api/v1/reports", body)
      |> json_response(400)
    end

    test "rejects invalid category", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      body = %{
        "reported_user_id" => ctx.reported_user_id,
        "category" => "not_a_category"
      }

      post(conn, ~p"/messaging/api/v1/reports", body)
      |> json_response(400)
    end
  end

  describe "POST /api/v1/moderation/report (frontend compatibility)" do
    test "creates a report via Imane's frontend route", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      body = %{
        "reported_user_id" => ctx.reported_user_id,
        "conversation_id" => ctx.conversation.id,
        "message_id" => ctx.message.id,
        "category" => "spam"
      }

      response =
        post(conn, "/api/v1/moderation/report", body)
        |> json_response(201)

      assert response["data"]["category"] == "spam"
    end
  end

  describe "GET /messaging/api/v1/reports" do
    test "lists my reports", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      # Create a report first
      post(conn, ~p"/messaging/api/v1/reports", %{
        "reported_user_id" => ctx.reported_user_id,
        "category" => "spam"
      })

      response =
        get(conn, ~p"/messaging/api/v1/reports")
        |> json_response(200)

      assert response["data"] != []
    end
  end

  describe "GET /messaging/api/v1/reports/queue" do
    test "lists pending reports for admin", ctx do
      # Create a report
      reporter_conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      post(reporter_conn, ~p"/messaging/api/v1/reports", %{
        "reported_user_id" => ctx.reported_user_id,
        "category" => "harassment"
      })

      admin_conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      response =
        get(admin_conn, ~p"/messaging/api/v1/reports/queue")
        |> json_response(200)

      assert response["data"] != []
      assert hd(response["data"])["status"] == "pending"
    end
  end

  describe "PUT /messaging/api/v1/reports/:id/resolve" do
    test "admin resolves a report", ctx do
      reporter_conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      %{"data" => %{"id" => report_id}} =
        post(reporter_conn, ~p"/messaging/api/v1/reports", %{
          "reported_user_id" => ctx.reported_user_id,
          "category" => "spam"
        })
        |> json_response(201)

      admin_conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      response =
        put(admin_conn, ~p"/messaging/api/v1/reports/#{report_id}/resolve", %{
          "action" => "dismiss",
          "notes" => "Not a violation"
        })
        |> json_response(200)

      assert response["data"]["status"] == "resolved_dismissed"
    end
  end
end
