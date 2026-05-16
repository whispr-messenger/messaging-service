defmodule WhisprMessagingWeb.ConversationAuthorizationTest do
  @moduledoc """
  Unit tests for the authorization helpers extracted from ConversationController.
  """
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessagingWeb.ConversationAuthorization

  describe "user_is_member?/2" do
    test "returns false for nil user_id" do
      refute ConversationAuthorization.user_is_member?(
               %{members: [%{user_id: "u1"}]},
               nil
             )
    end

    test "returns true when user appears in members list" do
      assert ConversationAuthorization.user_is_member?(
               %{members: [%{user_id: "u1"}, %{user_id: "u2"}]},
               "u2"
             )
    end

    test "returns false when user is not in members list" do
      refute ConversationAuthorization.user_is_member?(
               %{members: [%{user_id: "u1"}]},
               "u-stranger"
             )
    end

    test "returns false when :members is missing" do
      refute ConversationAuthorization.user_is_member?(%{type: "direct"}, "u1")
    end

    test "returns false when :members is %Ecto.Association.NotLoaded{}" do
      not_loaded = %Ecto.Association.NotLoaded{}
      refute ConversationAuthorization.user_is_member?(%{members: not_loaded}, "u1")
    end
  end

  describe "member?/2" do
    setup do
      u1 = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(conv.id, u1)

      %{conv: conv, u1: u1}
    end

    test "returns false for nil user_id", _ctx do
      refute ConversationAuthorization.member?(Ecto.UUID.generate(), nil)
    end

    test "returns true for an active member", ctx do
      assert ConversationAuthorization.member?(ctx.conv.id, ctx.u1)
    end

    test "returns false for a stranger", ctx do
      refute ConversationAuthorization.member?(ctx.conv.id, Ecto.UUID.generate())
    end
  end

  describe "can_manage_members?/2" do
    setup do
      admin_uid = Ecto.UUID.generate()
      reg_uid = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Admin Test"},
          is_active: true
        })

      {:ok, admin_member} = Conversations.add_conversation_member(conv.id, admin_uid)
      {:ok, _} = Conversations.add_conversation_member(conv.id, reg_uid)
      {:ok, _} = Conversations.set_member_role(admin_member, "admin")

      %{conv: conv, admin_uid: admin_uid, reg_uid: reg_uid}
    end

    test "returns false for nil user_id", ctx do
      refute ConversationAuthorization.can_manage_members?(ctx.conv, nil)
    end

    test "returns true for an admin", ctx do
      assert ConversationAuthorization.can_manage_members?(ctx.conv, ctx.admin_uid)
    end

    test "returns false for a regular member", ctx do
      refute ConversationAuthorization.can_manage_members?(ctx.conv, ctx.reg_uid)
    end

    test "returns false for a non-member", ctx do
      refute ConversationAuthorization.can_manage_members?(ctx.conv, Ecto.UUID.generate())
    end
  end

  describe "can_delete_conversation?/2" do
    setup do
      admin_uid = Ecto.UUID.generate()
      reg_uid = Ecto.UUID.generate()

      {:ok, direct} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(direct.id, reg_uid)

      {:ok, group} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "delete-test"},
          is_active: true
        })

      {:ok, admin_member} = Conversations.add_conversation_member(group.id, admin_uid)
      {:ok, _} = Conversations.add_conversation_member(group.id, reg_uid)
      {:ok, _} = Conversations.set_member_role(admin_member, "admin")

      %{
        direct: direct,
        group: group,
        admin_uid: admin_uid,
        reg_uid: reg_uid
      }
    end

    test "returns false for nil user_id", ctx do
      refute ConversationAuthorization.can_delete_conversation?(ctx.direct, nil)
    end

    test "direct conversation: any member can delete", ctx do
      assert ConversationAuthorization.can_delete_conversation?(ctx.direct, ctx.reg_uid)
    end

    test "direct conversation: non-member cannot delete", ctx do
      refute ConversationAuthorization.can_delete_conversation?(
               ctx.direct,
               Ecto.UUID.generate()
             )
    end

    test "group conversation: admin can delete", ctx do
      assert ConversationAuthorization.can_delete_conversation?(ctx.group, ctx.admin_uid)
    end

    test "group conversation: regular member cannot delete", ctx do
      refute ConversationAuthorization.can_delete_conversation?(ctx.group, ctx.reg_uid)
    end
  end

  describe "admin?/2" do
    setup do
      admin_uid = Ecto.UUID.generate()
      reg_uid = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "Admin Test"},
          is_active: true
        })

      {:ok, admin_member} = Conversations.add_conversation_member(conv.id, admin_uid)
      {:ok, _} = Conversations.add_conversation_member(conv.id, reg_uid)
      {:ok, _} = Conversations.set_member_role(admin_member, "admin")

      %{conv: conv, admin_uid: admin_uid, reg_uid: reg_uid}
    end

    test "returns false for nil user_id", ctx do
      refute ConversationAuthorization.admin?(ctx.conv.id, nil)
    end

    test "returns true for an admin", ctx do
      assert ConversationAuthorization.admin?(ctx.conv.id, ctx.admin_uid)
    end

    test "returns false for a regular member", ctx do
      refute ConversationAuthorization.admin?(ctx.conv.id, ctx.reg_uid)
    end

    test "returns false for a non-member", ctx do
      refute ConversationAuthorization.admin?(ctx.conv.id, Ecto.UUID.generate())
    end
  end

  describe "active_member?/2" do
    setup do
      uid = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "AM Test"},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(conv.id, uid)
      %{conv: conv, uid: uid}
    end

    test "returns false for nil user_id", ctx do
      refute ConversationAuthorization.active_member?(ctx.conv.id, nil)
    end

    test "returns true for an active member", ctx do
      assert ConversationAuthorization.active_member?(ctx.conv.id, ctx.uid)
    end

    test "returns false for a non-member", ctx do
      refute ConversationAuthorization.active_member?(ctx.conv.id, Ecto.UUID.generate())
    end
  end

  describe "is_active gating (WHISPR-1507 Copilot review)" do
    setup do
      admin_uid = Ecto.UUID.generate()
      reg_uid = Ecto.UUID.generate()

      {:ok, conv} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "gating"},
          is_active: true
        })

      {:ok, admin_member} = Conversations.add_conversation_member(conv.id, admin_uid)
      {:ok, _reg_member} = Conversations.add_conversation_member(conv.id, reg_uid)
      {:ok, _} = Conversations.set_member_role(admin_member, "admin")

      # Deactivate the regular member (simulates a removal/leave).
      {:ok, _} = Conversations.remove_conversation_member(conv.id, reg_uid)

      %{conv: conv, admin_uid: admin_uid, reg_uid: reg_uid}
    end

    test "member?/2 rejects an inactive (removed) member", ctx do
      refute ConversationAuthorization.member?(ctx.conv.id, ctx.reg_uid)
    end

    test "user_is_member?/2 rejects an inactive member when the preload exposes is_active",
         ctx do
      conv =
        WhisprMessaging.Repo.preload(ctx.conv, :members, force: true)

      # Sanity: the inactive member is still in the preload but flagged.
      assert Enum.any?(conv.members, fn m ->
               m.user_id == ctx.reg_uid and m.is_active == false
             end)

      refute ConversationAuthorization.user_is_member?(conv, ctx.reg_uid)
      assert ConversationAuthorization.user_is_member?(conv, ctx.admin_uid)
    end

    test "can_manage_members?/2 rejects an inactive admin even if their settings still say admin",
         ctx do
      # Deactivate the admin too (e.g. they left or were removed).
      {:ok, _} = Conversations.remove_conversation_member(ctx.conv.id, ctx.admin_uid)

      refute ConversationAuthorization.can_manage_members?(ctx.conv, ctx.admin_uid)
    end
  end
end
