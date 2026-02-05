defmodule WhisprMessagingWeb.AuthSecurityTest do
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    Conversations.add_conversation_member(conversation.id, user1_id)

    %{
      user1_id: user1_id,
      user2_id: user2_id,
      conversation: conversation
    }
  end

  test "GET /api/v1/conversations fails if no auth header provided, even with user_id in params", %{user1_id: user1_id} do
    conn =
      build_conn()
      |> json_conn()

    # Attempt to impersonate user1 using params
    response =
      get(conn, ~p"/api/v1/conversations", user_id: user1_id)
      |> json_response(401)

    assert response["error"] == "Unauthorized"
  end

  test "GET /api/v1/conversations fails with invalid Bearer token", %{user1_id: user1_id} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer invalid_token")
      |> json_conn()

    response =
      get(conn, ~p"/api/v1/conversations", user_id: user1_id)
      |> json_response(401)

    assert response["error"] == "Unauthorized"
  end

  test "GET /api/v1/conversations succeeds with X-User-Id header", %{user1_id: user1_id} do
    conn =
      build_conn()
      |> put_req_header("x-user-id", user1_id)
      |> json_conn()

    response =
      get(conn, ~p"/api/v1/conversations")
      |> json_response(200)

    assert response["data"] != nil
  end

  test "GET /api/v1/conversations succeeds with valid test token", %{user1_id: user1_id} do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer test_token_#{user1_id}")
      |> json_conn()

    response =
      get(conn, ~p"/api/v1/conversations")
      |> json_response(200)

    assert response["data"] != nil
  end
end
