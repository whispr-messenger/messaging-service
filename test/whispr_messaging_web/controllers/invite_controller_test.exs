defmodule WhisprMessagingWeb.InviteControllerTest do
  @moduledoc """
  Controller tests for group invite links (WHISPR-1046).
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember}
  alias WhisprMessaging.Invites
  alias WhisprMessaging.Repo

  setup do
    admin_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()
    stranger_id = Ecto.UUID.generate()
    joiner_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Invite test group"},
        is_active: true,
        e2ee_enabled: false
      })

    admin_settings =
      ConversationMember.default_settings()
      |> Map.put("role", "admin")

    {:ok, _} = Conversations.add_conversation_member(conversation.id, admin_id, admin_settings)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, member_id)

    %{
      conversation: conversation,
      admin_id: admin_id,
      member_id: member_id,
      stranger_id: stranger_id,
      joiner_id: joiner_id
    }
  end

  describe "POST /conversations/:id/invite_link" do
    test "admin can generate an invite link", ctx do
      body =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/invite_link")
        |> json_response(201)

      assert %{"token" => token, "url" => url, "expiresAt" => expires_at} = body["data"]
      assert is_binary(token) and byte_size(token) > 0
      assert url == "whispr://invite/#{token}"
      assert is_binary(expires_at)
    end

    test "non-admin member cannot generate an invite", ctx do
      build_conn()
      |> authenticated_conn(ctx.member_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/invite_link")
      |> json_response(403)
    end

    test "stranger cannot generate an invite", ctx do
      build_conn()
      |> authenticated_conn(ctx.stranger_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/invite_link")
      |> json_response(403)
    end
  end

  describe "DELETE /conversations/:id/invite_link" do
    test "admin can revoke an existing invite", ctx do
      {:ok, _} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      build_conn()
      |> authenticated_conn(ctx.admin_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/invite_link")
      |> response(204)

      assert %Conversation{invite_token: nil, invite_expires_at: nil} =
               Repo.get!(Conversation, ctx.conversation.id)
    end

    test "non-admin cannot revoke", ctx do
      {:ok, _} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      build_conn()
      |> authenticated_conn(ctx.member_id)
      |> json_conn()
      |> delete(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/invite_link")
      |> json_response(403)
    end
  end

  describe "POST /invites/:token/join" do
    test "user can join with a valid token", ctx do
      {:ok, conversation} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      body =
        build_conn()
        |> authenticated_conn(ctx.joiner_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
        |> json_response(201)

      assert body["data"]["conversationId"] == ctx.conversation.id
      assert body["data"]["alreadyMember"] == false

      assert %ConversationMember{is_active: true} =
               Conversations.get_conversation_member(ctx.conversation.id, ctx.joiner_id)
    end

    test "existing member joining the same invite returns alreadyMember", ctx do
      {:ok, conversation} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      body =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
        |> json_response(200)

      assert body["data"]["alreadyMember"] == true
    end

    test "revoked token returns 404", ctx do
      {:ok, conversation} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)
      {:ok, _} = Invites.revoke_invite(ctx.conversation.id, ctx.admin_id)

      build_conn()
      |> authenticated_conn(ctx.joiner_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
      |> json_response(404)
    end

    test "expired token returns 404", ctx do
      {:ok, conversation} =
        Invites.generate_invite(ctx.conversation.id, ctx.admin_id, ttl_seconds: 1)

      past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)

      conversation
      |> Conversation.invite_changeset(%{invite_expires_at: past})
      |> Repo.update!()

      build_conn()
      |> authenticated_conn(ctx.joiner_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
      |> json_response(404)
    end

    test "unknown token returns 404", ctx do
      random_token = Ecto.UUID.generate()

      build_conn()
      |> authenticated_conn(ctx.joiner_id)
      |> json_conn()
      |> post(~p"/messaging/api/v1/invites/#{random_token}/join")
      |> json_response(404)
    end

    # WHISPR-1416 — un kické ne se re-invite pas silencieusement via le lien
    test "previously kicked user cannot rejoin via invite link", ctx do
      {:ok, conversation} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      # on simule un kick : l'admin retire member_id
      {:ok, _} = Conversations.remove_conversation_member(ctx.conversation.id, ctx.member_id)

      body =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
        |> json_response(400)

      assert body["error"] =~ "previously kicked"

      # le membre reste inactif (pas de réactivation silencieuse)
      assert %ConversationMember{is_active: false} =
               Conversations.get_conversation_member(ctx.conversation.id, ctx.member_id)
    end

    # WHISPR-1416 — plafond de membres pour bloquer le flood via invite link
    test "join is rejected when group has reached the member cap", ctx do
      {:ok, conversation} = Invites.generate_invite(ctx.conversation.id, ctx.admin_id)

      # remplir le groupe jusqu'au plafond (256) avant le join du joiner
      filler_count = 256 - Conversations.count_conversation_members(ctx.conversation.id)

      Enum.each(1..filler_count, fn _ ->
        Conversations.add_conversation_member(ctx.conversation.id, Ecto.UUID.generate())
      end)

      body =
        build_conn()
        |> authenticated_conn(ctx.joiner_id)
        |> json_conn()
        |> post(~p"/messaging/api/v1/invites/#{conversation.invite_token}/join")
        |> json_response(400)

      assert body["error"] =~ "member cap"

      assert is_nil(Conversations.get_conversation_member(ctx.conversation.id, ctx.joiner_id))
    end
  end
end
