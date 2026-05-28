defmodule WhisprMessagingWeb.InternalConversationControllerTest do
  @moduledoc """
  Tests pour GET /messaging/api/v1/internal/conversations/:id/e2ee-status.
  Endpoint consomme par media-service pour refuser les uploads plaintext
  sur les conversations E2EE (defense in depth).
  """

  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.Conversations

  @internal_token "test-internal-token"

  defp with_internal_token(conn, token \\ @internal_token) do
    put_req_header(conn, "x-internal-token", token)
  end

  setup do
    {:ok, direct_conv} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true,
        # e2ee_enabled=true par defaut depuis PR #132 - forcer false pour ce test plaintext
        e2ee_enabled: false
      })

    {:ok, e2ee_conv} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    Conversations.update_e2ee(e2ee_conv, %{e2ee_enabled: true})
    # Recharger depuis la DB pour avoir l'etat persiste
    e2ee_conv = Conversations.get_conversation!(e2ee_conv.id)

    %{direct_conv: direct_conv, e2ee_conv: e2ee_conv}
  end

  describe "GET /messaging/api/v1/internal/conversations/:id/e2ee-status" do
    test "retourne 404 sans le header x-internal-token", %{direct_conv: conv} do
      conn =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/e2ee-status")

      assert conn.status == 404
    end

    test "retourne 404 avec un token invalide", %{direct_conv: conv} do
      conn =
        build_conn()
        |> json_conn()
        |> with_internal_token("mauvais-token")
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/e2ee-status")

      assert conn.status == 404
    end

    test "retourne e2ee_enabled=false pour une conv plaintext", %{direct_conv: conv} do
      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/e2ee-status")
        |> json_response(200)

      assert resp["e2ee_enabled"] == false
      assert resp["conversation_id"] == conv.id
    end

    test "retourne e2ee_enabled=true pour une conv E2EE", %{e2ee_conv: conv} do
      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/e2ee-status")
        |> json_response(200)

      assert resp["e2ee_enabled"] == true
      assert resp["conversation_id"] == conv.id
    end

    test "retourne 404 pour une conversation inexistante" do
      unknown_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{unknown_id}/e2ee-status")

      assert conn.status == 404
    end
  end

  describe "GET /messaging/api/v1/internal/conversations/:id/members/:user_id" do
    test "retourne 404 sans le header x-internal-token", %{direct_conv: conv} do
      user_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> json_conn()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/members/#{user_id}")

      assert conn.status == 404
    end

    test "retourne is_member=true pour un membre actif", %{direct_conv: conv} do
      user_id = Ecto.UUID.generate()
      {:ok, _member} = Conversations.add_conversation_member(conv.id, user_id)

      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/members/#{user_id}")
        |> json_response(200)

      assert resp["is_member"] == true
      assert resp["conversation_id"] == conv.id
      assert resp["user_id"] == user_id
    end

    test "retourne is_member=false pour un non-membre", %{direct_conv: conv} do
      user_id = Ecto.UUID.generate()

      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{conv.id}/members/#{user_id}")
        |> json_response(200)

      assert resp["is_member"] == false
    end

    test "retourne is_member=false pour une conversation inexistante" do
      unknown_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      resp =
        build_conn()
        |> json_conn()
        |> with_internal_token()
        |> get(~p"/messaging/api/v1/internal/conversations/#{unknown_id}/members/#{user_id}")
        |> json_response(200)

      assert resp["is_member"] == false
    end
  end
end
