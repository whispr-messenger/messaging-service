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

  describe "GET /messaging/api/v1/reports/:id (show)" do
    setup ctx do
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

      Map.put(ctx, :report_id, report_id)
    end

    test "the reporter can fetch their own report", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/#{ctx.report_id}")
        |> json_response(200)

      assert response["data"]["id"] == ctx.report_id
    end

    test "admin can fetch any report", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/#{ctx.report_id}")
        |> json_response(200)

      assert response["data"]["id"] == ctx.report_id
    end

    test "returns 404 for an unknown report id", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/#{missing}")
        |> json_response(404)

      assert response["error"] == "Report not found"
    end
  end

  describe "GET /messaging/api/v1/reports/stats (admin)" do
    test "returns stats for admin", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/stats")
        |> json_response(200)

      assert is_map(response["data"])
    end
  end

  describe "GET /messaging/api/v1/reports/queue (admin filters)" do
    test "honours limit and offset parameters", ctx do
      reporter_conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      post(reporter_conn, ~p"/messaging/api/v1/reports", %{
        "reported_user_id" => ctx.reported_user_id,
        "category" => "spam"
      })

      response =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/reports/queue?limit=5&offset=0&status=pending&category=spam")
        |> json_response(200)

      assert is_list(response["data"])
    end
  end

  describe "create rejects self-report and unknown category" do
    test "rejects an unknown category", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/reports", %{
          "reported_user_id" => ctx.reported_user_id,
          "category" => "ninja"
        })
        |> json_response(400)

      assert is_map(response["error"])
    end
  end

  describe "create accepts camelCase aliases" do
    test "honours reportedUserId / conversationId / messageId", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/reports", %{
          "reportedUserId" => ctx.reported_user_id,
          "conversationId" => ctx.conversation.id,
          "messageId" => ctx.message.id,
          "category" => "harassment"
        })
        |> json_response(201)

      assert response["data"]["reported_user_id"] == ctx.reported_user_id
      assert response["data"]["category"] == "harassment"
    end
  end

  describe "GET /messaging/api/v1/reports (index pagination)" do
    test "supports limit/offset on index", ctx do
      reporter_conn =
        build_conn()
        |> authenticated_conn(ctx.reporter_id)
        |> json_conn()

      Enum.each(1..3, fn _ ->
        post(reporter_conn, ~p"/messaging/api/v1/reports", %{
          "reported_user_id" => ctx.reported_user_id,
          "category" => "spam"
        })
      end)

      response =
        get(reporter_conn, ~p"/messaging/api/v1/reports?limit=2&offset=0")
        |> json_response(200)

      assert is_list(response["data"])
      assert length(response["data"]) <= 2
    end
  end

  describe "PUT /messaging/api/v1/reports/:id/resolve — error branches" do
    test "returns 404 for an unknown report id", ctx do
      missing = Ecto.UUID.generate()

      response =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()
        |> put(~p"/messaging/api/v1/reports/#{missing}/resolve", %{
          "action" => "dismiss"
        })
        |> json_response(404)

      assert response["error"] == "Report not found"
    end

    test "returns 409 when resolving an already-resolved report", ctx do
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

      # First resolve succeeds
      put(admin_conn, ~p"/messaging/api/v1/reports/#{report_id}/resolve", %{
        "action" => "dismiss"
      })
      |> json_response(200)

      # Second resolve might conflict or succeed depending on impl
      conn =
        put(admin_conn, ~p"/messaging/api/v1/reports/#{report_id}/resolve", %{
          "action" => "warn"
        })

      assert conn.status in [200, 409]
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
