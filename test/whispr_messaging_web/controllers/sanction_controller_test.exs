defmodule WhisprMessagingWeb.SanctionControllerTest do
  use WhisprMessagingWeb.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations

  setup do
    Sandbox.mode(WhisprMessaging.Repo, :auto)

    admin_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Test"},
        is_active: true
      })

    %{admin_id: admin_id, user_id: user_id, conversation: conversation}
  end

  describe "POST /messaging/api/v1/conversations/:id/sanctions" do
    test "creates a mute sanction", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body = %{
        "user_id" => ctx.user_id,
        "type" => "mute",
        "reason" => "Spamming in group",
        "expires_at" => DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601()
      }

      response =
        post(conn, ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/sanctions", body)
        |> json_response(201)

      assert response["data"]["type"] == "mute"
      assert response["data"]["active"] == true
    end
  end

  describe "GET /messaging/api/v1/conversations/:id/sanctions" do
    test "lists active sanctions", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      # Create a sanction first
      post(conn, ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/sanctions", %{
        "user_id" => ctx.user_id,
        "type" => "mute",
        "reason" => "Test"
      })

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/sanctions")
        |> json_response(200)

      assert response["data"] != []
    end
  end

  describe "DELETE /messaging/api/v1/conversations/:id/sanctions/:sid" do
    test "lifts a sanction", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      %{"data" => %{"id" => sanction_id}} =
        post(conn, ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/sanctions", %{
          "user_id" => ctx.user_id,
          "type" => "mute",
          "reason" => "Test"
        })
        |> json_response(201)

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/sanctions/#{sanction_id}"
        )
        |> json_response(200)

      assert response["message"] == "Sanction lifted"
    end
  end
end
