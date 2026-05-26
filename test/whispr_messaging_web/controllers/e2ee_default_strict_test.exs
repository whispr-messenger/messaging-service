defmodule WhisprMessagingWeb.E2eeDefaultStrictTest do
  @moduledoc """
  Tests E2EE force par defaut + validation stricte + endpoint Option Z.
  Couvre la migration 20260526230001 et les nouvelles regles metier.
  """

  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.{Conversations, Messages, Repo}
  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.Message

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()
    outsider_id = Ecto.UUID.generate()

    # Conv directe sans e2ee_enabled explicite — doit defaulter a true
    {:ok, direct_conv_e2ee} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    # Conv directe explicitement plaintext (anciennes convs)
    {:ok, direct_conv_plain} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true,
        e2ee_enabled: false
      })

    # Conv groupe sans e2ee_enabled explicite — doit defaulter a true
    {:ok, group_conv_e2ee} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Groupe Test"},
        is_active: true
      })

    # Conv groupe plaintext (anciennes convs)
    {:ok, group_conv_plain} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Groupe Plain"},
        is_active: true,
        e2ee_enabled: false
      })

    for conv <- [direct_conv_e2ee, direct_conv_plain, group_conv_e2ee, group_conv_plain] do
      {:ok, _} = Conversations.add_conversation_member(conv.id, user1_id)
      {:ok, _} = Conversations.add_conversation_member(conv.id, user2_id)
    end

    %{
      direct_conv_e2ee: direct_conv_e2ee,
      direct_conv_plain: direct_conv_plain,
      group_conv_e2ee: group_conv_e2ee,
      group_conv_plain: group_conv_plain,
      user1_id: user1_id,
      user2_id: user2_id,
      outsider_id: outsider_id
    }
  end

  # ---------------------------------------------------------------------------
  # 1. Default e2ee_enabled=true sur les nouvelles convs
  # ---------------------------------------------------------------------------

  describe "create_conversation/1 - e2ee_enabled par defaut" do
    test "une conv directe sans e2ee_enabled est creee avec e2ee_enabled=true", %{
      direct_conv_e2ee: conv
    } do
      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.e2ee_enabled == true
    end

    test "une conv groupe sans e2ee_enabled est creee avec e2ee_enabled=true", %{
      group_conv_e2ee: conv
    } do
      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.e2ee_enabled == true
    end

    test "une conv creee avec e2ee_enabled=false reste a false (backcompat anciennes convs)", %{
      direct_conv_plain: conv
    } do
      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.e2ee_enabled == false
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Validation stricte serveur sur create_message
  # ---------------------------------------------------------------------------

  describe "Messages.create_message/1 - politique E2EE stricte" do
    test "refuse plaintext sur conv e2ee_enabled=true -> :plaintext_not_allowed_on_e2ee_conversation",
         %{direct_conv_e2ee: conv, user1_id: user1_id} do
      result =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content: "bonjour en clair",
          client_random: System.unique_integer([:positive])
        })

      assert {:error, :plaintext_not_allowed_on_e2ee_conversation} = result
    end

    test "accepte ciphertext olm_v1 sur conv e2ee_enabled=true", %{
      direct_conv_e2ee: conv,
      user1_id: user1_id
    } do
      result =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content_format: "olm_v1",
          ciphertext: <<0xDE, 0xAD, 0xBE, 0xEF>>,
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, %Message{content_format: "olm_v1"}} = result
    end

    test "accepte plaintext sur conv e2ee_enabled=false (comportement actuel)", %{
      direct_conv_plain: conv,
      user1_id: user1_id
    } do
      result =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content: "bonjour",
          client_random: System.unique_integer([:positive])
        })

      assert {:ok, %Message{content_format: "plaintext"}} = result
    end

    test "refuse olm_v1 sans ciphertext meme sur conv e2ee=true", %{
      direct_conv_e2ee: conv,
      user1_id: user1_id
    } do
      result =
        Messages.create_message(%{
          conversation_id: conv.id,
          sender_id: user1_id,
          message_type: "text",
          content_format: "olm_v1",
          client_random: System.unique_integer([:positive])
        })

      # La validation olm_v1 sans ciphertext retourne une erreur de changeset
      assert {:error, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # 3. POST /conversations/:id/messages - validation HTTP
  # ---------------------------------------------------------------------------

  describe "POST /conversations/:id/messages - E2EE stricte HTTP" do
    test "plaintext sur conv e2ee=true retourne 422 plaintext_not_allowed_on_e2ee_conversation",
         %{direct_conv_e2ee: conv, user1_id: user1_id} do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{conv.id}/messages", %{
          "message_type" => "text",
          "content" => "bonjour en clair",
          "client_random" => System.unique_integer([:positive])
        })

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "plaintext_not_allowed_on_e2ee_conversation"
    end

    test "ciphertext olm_v1 sur conv e2ee=true retourne 201", %{
      direct_conv_e2ee: conv,
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
    end

    test "plaintext sur conv e2ee=false retourne 201", %{
      direct_conv_plain: conv,
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
    end
  end

  # ---------------------------------------------------------------------------
  # 4. PATCH /conversations/:id/e2ee - Option Z (upgrade irreversible)
  # ---------------------------------------------------------------------------

  describe "PATCH /conversations/:id/e2ee - Option Z" do
    test "upgrade false->true retourne 204 et persiste e2ee_enabled=true", %{
      direct_conv_plain: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => true})

      assert conn.status == 204
      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.e2ee_enabled == true
    end

    test "idempotent si deja true -> 204 sans erreur", %{
      direct_conv_e2ee: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => true})

      assert conn.status == 204
    end

    test "downgrade (enable=false) retourne 400 e2ee_downgrade_forbidden", %{
      direct_conv_e2ee: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => false})

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "e2ee_downgrade_forbidden"
    end

    test "manque de enable retourne 400", %{direct_conv_plain: conv, user1_id: user1_id} do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{})

      assert conn.status == 400
    end

    test "non-membre retourne 403", %{direct_conv_plain: conv, outsider_id: outsider_id} do
      conn =
        build_conn()
        |> authenticated_conn(outsider_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => true})

      assert conn.status == 403
    end

    test "sans auth retourne 401", %{direct_conv_plain: conv} do
      conn =
        build_conn()
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => true})

      assert conn.status == 401
    end

    test "fonctionne aussi sur un groupe (Option Z accepte direct ET group)", %{
      group_conv_plain: conv,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()
        |> patch(~p"/messaging/api/v1/conversations/#{conv.id}/e2ee", %{"enable" => true})

      assert conn.status == 204
      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.e2ee_enabled == true
    end
  end
end
