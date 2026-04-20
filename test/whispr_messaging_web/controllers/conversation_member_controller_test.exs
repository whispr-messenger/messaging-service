defmodule WhisprMessagingWeb.ConversationMemberControllerTest do
  @moduledoc """
  Controller tests for conversation member admin permissions (WHISPR-965).
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ConversationMember

  setup do
    admin_id = Ecto.UUID.generate()
    member_id = Ecto.UUID.generate()
    other_member_id = Ecto.UUID.generate()
    stranger_id = Ecto.UUID.generate()
    new_user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Admin test group"},
        is_active: true
      })

    admin_settings =
      ConversationMember.default_settings()
      |> Map.put("role", "admin")

    {:ok, _} = Conversations.add_conversation_member(conversation.id, admin_id, admin_settings)
    {:ok, member} = Conversations.add_conversation_member(conversation.id, member_id)

    # other_member joins a bit later, to give us a deterministic
    # "oldest member" for auto-promote tests.
    Process.sleep(10)

    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_member_id)

    %{
      conversation: conversation,
      admin_id: admin_id,
      member_id: member_id,
      other_member_id: other_member_id,
      stranger_id: stranger_id,
      new_user_id: new_user_id,
      member: member
    }
  end

  describe "POST /conversations/:id/members (admin gate)" do
    test "admin can add a new member", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      response =
        conn
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members", %{
          "user_id" => ctx.new_user_id
        })
        |> json_response(201)

      assert response["data"]["userId"] == ctx.new_user_id
    end

    test "non-admin member cannot add members", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()

      conn
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members", %{
        "user_id" => ctx.new_user_id
      })
      |> json_response(403)
    end

    test "stranger cannot add members", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.stranger_id)
        |> json_conn()

      conn
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members", %{
        "user_id" => ctx.new_user_id
      })
      |> json_response(403)
    end
  end

  describe "DELETE /conversations/:id/members/:user_id" do
    test "admin can remove a plain member", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.member_id}"
        )

      assert response.status == 204
    end

    test "non-admin cannot remove members", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()

      conn
      |> delete(
        ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.other_member_id}"
      )
      |> json_response(403)
    end

    test "admin cannot delete themselves via DELETE (must use leave)", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body =
        conn
        |> delete(
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.admin_id}"
        )
        |> json_response(400)

      assert body["error"] =~ "Cannot remove yourself"
    end
  end

  describe "PATCH /conversations/:id/members/:user_id/role" do
    test "admin can promote a member to admin", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body =
        conn
        |> patch(
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.member_id}/role",
          %{"role" => "admin"}
        )
        |> json_response(200)

      assert body["data"]["role"] == "admin"
    end

    test "admin can demote another admin when they are not the only one", ctx do
      # Promote member first.
      {:ok, _} =
        Conversations.set_member_role(
          Conversations.get_conversation_member(ctx.conversation.id, ctx.member_id),
          "admin"
        )

      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body =
        conn
        |> patch(
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.member_id}/role",
          %{"role" => "member"}
        )
        |> json_response(200)

      assert body["data"]["role"] == "member"
    end

    test "only remaining admin cannot demote themselves (anti-self-lock)", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body =
        conn
        |> patch(
          ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.admin_id}/role",
          %{"role" => "member"}
        )
        |> json_response(400)

      assert body["error"] =~ "only admin"
    end

    test "non-admin cannot change any role", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()

      conn
      |> patch(
        ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.other_member_id}/role",
        %{"role" => "admin"}
      )
      |> json_response(403)
    end

    test "invalid role is rejected", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      conn
      |> patch(
        ~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/members/#{ctx.member_id}/role",
        %{"role" => "superuser"}
      )
      |> json_response(400)
    end
  end

  describe "POST /conversations/:id/leave" do
    test "plain member leaves without auto-promote", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.member_id)
        |> json_conn()

      body =
        conn
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/leave")
        |> json_response(200)

      assert body["data"]["left"] == true
      assert body["data"]["autoPromotedUserId"] in [nil, ""]
      assert body["data"]["conversationDeactivated"] == false

      # The admin is still admin.
      admins = Conversations.list_admin_members(ctx.conversation.id)
      assert length(admins) == 1
    end

    test "last admin leaves: oldest remaining member is auto-promoted", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.admin_id)
        |> json_conn()

      body =
        conn
        |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/leave")
        |> json_response(200)

      # The oldest joined remaining member is ctx.member_id (joined before other_member).
      assert body["data"]["autoPromotedUserId"] == ctx.member_id
      assert body["data"]["conversationDeactivated"] == false

      admins = Conversations.list_admin_members(ctx.conversation.id)
      assert Enum.any?(admins, fn m -> m.user_id == ctx.member_id end)
    end

    test "solo admin leaves an empty group: conversation is deactivated", _ctx do
      solo_admin_id = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Solo group"},
          is_active: true
        })

      admin_settings =
        ConversationMember.default_settings() |> Map.put("role", "admin")

      {:ok, _} = Conversations.add_conversation_member(conv.id, solo_admin_id, admin_settings)

      conn =
        build_conn()
        |> authenticated_conn(solo_admin_id)
        |> json_conn()

      body =
        conn
        |> post(~p"/messaging/api/v1/conversations/#{conv.id}/leave")
        |> json_response(200)

      assert body["data"]["conversationDeactivated"] == true

      {:ok, reloaded} = Conversations.get_conversation(conv.id)
      refute reloaded.is_active
    end

    test "non-member cannot leave", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.stranger_id)
        |> json_conn()

      conn
      |> post(~p"/messaging/api/v1/conversations/#{ctx.conversation.id}/leave")
      |> json_response(404)
    end
  end

  describe "create_group_conversation" do
    test "creator is automatically admin" do
      creator = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_group_conversation(creator, [other], "Auto-admin group")

      creator_member = Conversations.get_conversation_member(conv.id, creator)
      other_member = Conversations.get_conversation_member(conv.id, other)

      assert Conversations.member_role(creator_member) == "admin"
      assert Conversations.member_role(other_member) == "member"
    end
  end
end
