defmodule WhisprMessagingWeb.E2eeControllerTest do
  @moduledoc """
  Tests d'integration E2EE — couvre WHISPR-1482, WHISPR-1483, WHISPR-1484,
  WHISPR-1485, WHISPR-1486.
  """

  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.{Conversations, Messages, Repo}
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Messages.Serializer

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    # Convs avec e2ee_enabled=false pour les tests de la phase 1 (bascule, plaintext, search)
    {:ok, direct_conv} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true,
        e2ee_enabled: false
      })

    {:ok, group_conv} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Test Group"},
        is_active: true,
        e2ee_enabled: false
      })

    {:ok, _} = Conversations.add_conversation_member(direct_conv.id, user1_id)
    {:ok, _} = Conversations.add_conversation_member(direct_conv.id, user2_id)
    {:ok, _} = Conversations.add_conversation_member(group_conv.id, user1_id)
    {:ok, _} = Conversations.add_conversation_member(group_conv.id, user2_id)

    %{
      direct_conv: direct_conv,
      group_conv: group_conv,
      user1_id: user1_id,
      user2_id: user2_id,
      outsider_id: outsider_id
    }
  end

  # -----------------------------------------------------------------------
  # WHISPR-1482 + 1486 — POST message avec ciphertext
  # -----------------------------------------------------------------------

  describe "POST /conversations/:id/messages - E2EE (WHISPR-1482, 1486)" do
    test "envoie un message E2EE (olm_v1) et le stocke correctement", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      ciphertext = Base.encode64(<<0xDE, 0xAD, 0xBE, 0xEF, 0x00>>)

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{conv.id}/messages", %{
          "message_type" => "text",
          "content_format" => "olm_v1",
          "ciphertext" => ciphertext,
          "client_random" => System.unique_integer([:positive])
        })

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["data"]["format"] == "olm_v1"
      assert body["data"]["ciphertext"] == ciphertext
      assert body["data"]["content"] == nil

      # Verification en base : content null, ciphertext stocke
      msg_id = body["data"]["id"]
      msg = Repo.get(Message, msg_id)
      assert msg.content_format == "olm_v1"
      assert msg.content == nil
      assert msg.ciphertext != nil
    end

    test "un message plaintext standard fonctionne toujours", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{conv.id}/messages", %{
          "message_type" => "text",
          "content" => "bonjour",
          "client_random" => System.unique_integer([:positive])
        })

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["data"]["format"] == "plaintext"
      assert body["data"]["content"] != nil
      assert body["data"]["ciphertext"] == nil
    end

    test "message olm_v1 sans ciphertext retourne 422", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{conv.id}/messages", %{
          "message_type" => "text",
          "content_format" => "olm_v1",
          "client_random" => System.unique_integer([:positive])
        })

      assert conn.status == 422
    end
  end

  # -----------------------------------------------------------------------
  # WHISPR-1484 — PATCH /conversations/:id/e2ee (Option Z - upgrade irreversible)
  # -----------------------------------------------------------------------

  describe "PATCH /conversations/:id/e2ee (WHISPR-1484)" do
    test "active E2EE sur une conv directe (enable=true)", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{
          "enable" => true
        })

      assert conn.status == 204

      updated = Repo.get(Conversations.Conversation, conv.id)
      assert updated.e2ee_enabled == true
    end

    test "downgrade (enable=false) retourne 400 e2ee_downgrade_forbidden", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      # D'abord upgrade pour avoir e2ee_enabled=true
      Conversations.update_e2ee(conv, %{e2ee_enabled: true})

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{
          "enable" => false
        })

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "e2ee_downgrade_forbidden"
    end

    test "retourne 400 si enable manquant", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{})

      assert conn.status == 400
    end

    test "retourne 403 pour un non-membre", %{
      direct_conv: conv,
      outsider_id: outsider_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(outsider_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{
          "enable" => true
        })

      assert conn.status == 403
    end

    test "retourne 401 sans authentification", %{direct_conv: conv} do
      conn =
        build_conn()
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{
          "enable" => true
        })

      assert conn.status == 401
    end
  end

  # -----------------------------------------------------------------------
  # WHISPR-1485 — Recherche exclut les convs E2EE
  # -----------------------------------------------------------------------

  describe "GET /messages/search - filtre E2EE (WHISPR-1485)" do
    test "la recherche n'indexe pas les messages d'une conv e2ee_enabled=true", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      # Activer E2EE sur la conv
      Conversations.update_e2ee(conv, %{e2ee_enabled: true})

      # Stocker un message ciphertext
      Messages.create_message(%{
        conversation_id: conv.id,
        sender_id: user1_id,
        message_type: "text",
        content_format: "olm_v1",
        ciphertext: <<0xDE, 0xAD>>,
        client_random: System.unique_integer([:positive])
      })

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search", %{"query" => "anything"})

      assert conn.status == 200
      # La search retourne une liste directe (pas {data: [...]})
      results = Jason.decode!(conn.resp_body)
      assert is_list(results)
      assert results == []
    end

    test "la recherche retourne les messages d'une conv plaintext", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      # S'assurer que E2EE est desactive
      Conversations.update_e2ee(conv, %{e2ee_enabled: false})

      unique_token = "whispr_e2ee_test_#{System.unique_integer([:positive])}"

      Messages.create_message(%{
        conversation_id: conv.id,
        sender_id: user1_id,
        message_type: "text",
        content: unique_token,
        client_random: System.unique_integer([:positive])
      })

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search", %{"query" => unique_token})

      assert conn.status == 200
      results = Jason.decode!(conn.resp_body)
      assert is_list(results)
      refute Enum.empty?(results)
    end
  end

  # -----------------------------------------------------------------------
  # WHISPR-1483 — Shape serializer coherente HTTP vs attendu
  # -----------------------------------------------------------------------

  describe "Serializer shape (WHISPR-1483)" do
    test "message E2EE retourne format, ciphertext, content nil", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      ciphertext_bin = <<0xAB, 0xCD, 0xEF>>
      ciphertext_b64 = Base.encode64(ciphertext_bin)

      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content_format: "olm_v1",
          ciphertext: ciphertext_bin,
          client_random: System.unique_integer([:positive])
        })

      serialized = Serializer.serialize(msg)
      assert serialized["format"] == "olm_v1"
      assert serialized["ciphertext"] == ciphertext_b64
      assert serialized["content"] == nil
    end

    test "message plaintext retourne format plaintext, content, ciphertext nil", %{
      direct_conv: conv,
      user1_id: user1_id
    } do
      {:ok, msg} =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content: "bonjour",
          client_random: System.unique_integer([:positive])
        })

      serialized = Serializer.serialize(msg)
      assert serialized["format"] == "plaintext"
      assert serialized["content"] != nil
      assert serialized["ciphertext"] == nil
    end
  end
end
