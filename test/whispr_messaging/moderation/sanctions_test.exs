defmodule WhisprMessaging.Moderation.SanctionsTest do
  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Moderation.Sanctions

  setup do
    Sandbox.mode(WhisprMessaging.Repo, :auto)

    conversation = create_test_conversation()
    user_id = create_test_user_id()
    admin_id = create_test_user_id()

    %{conversation: conversation, user_id: user_id, admin_id: admin_id}
  end

  describe "create_sanction/1" do
    test "creates a mute sanction", ctx do
      attrs = %{
        conversation_id: ctx.conversation.id,
        user_id: ctx.user_id,
        type: "mute",
        reason: "Spamming",
        issued_by: ctx.admin_id,
        expires_at: DateTime.utc_now() |> DateTime.add(86_400, :second)
      }

      assert {:ok, sanction} = Sanctions.create_sanction(attrs)
      assert sanction.type == "mute"
      assert sanction.active == true
    end

    test "creates a kick sanction", ctx do
      attrs = %{
        conversation_id: ctx.conversation.id,
        user_id: ctx.user_id,
        type: "kick",
        reason: "Harassment",
        issued_by: ctx.admin_id
      }

      assert {:ok, sanction} = Sanctions.create_sanction(attrs)
      assert sanction.type == "kick"
    end

    test "rejects invalid type", ctx do
      attrs = %{
        conversation_id: ctx.conversation.id,
        user_id: ctx.user_id,
        type: "invalid",
        reason: "Test",
        issued_by: ctx.admin_id
      }

      assert {:error, _changeset} = Sanctions.create_sanction(attrs)
    end
  end

  describe "lift_sanction/1" do
    test "deactivates an active sanction", ctx do
      {:ok, sanction} =
        Sanctions.create_sanction(%{
          conversation_id: ctx.conversation.id,
          user_id: ctx.user_id,
          type: "mute",
          reason: "Test",
          issued_by: ctx.admin_id
        })

      assert {:ok, lifted} = Sanctions.lift_sanction(sanction.id)
      assert lifted.active == false
    end

    test "returns error for already lifted sanction", ctx do
      {:ok, sanction} =
        Sanctions.create_sanction(%{
          conversation_id: ctx.conversation.id,
          user_id: ctx.user_id,
          type: "mute",
          reason: "Test",
          issued_by: ctx.admin_id
        })

      {:ok, _} = Sanctions.lift_sanction(sanction.id)
      assert {:error, :already_lifted} = Sanctions.lift_sanction(sanction.id)
    end
  end

  describe "active_sanction_for/2" do
    test "returns active sanction for user in conversation", ctx do
      {:ok, _} =
        Sanctions.create_sanction(%{
          conversation_id: ctx.conversation.id,
          user_id: ctx.user_id,
          type: "mute",
          reason: "Test",
          issued_by: ctx.admin_id
        })

      sanction = Sanctions.active_sanction_for(ctx.conversation.id, ctx.user_id)
      assert sanction != nil
      assert sanction.type == "mute"
    end

    test "returns nil when no active sanction", ctx do
      assert Sanctions.active_sanction_for(ctx.conversation.id, ctx.user_id) == nil
    end
  end

  describe "expire_sanctions/0" do
    test "deactivates expired sanctions", ctx do
      past = DateTime.utc_now() |> DateTime.add(-3_600, :second)

      {:ok, _} =
        Sanctions.create_sanction(%{
          conversation_id: ctx.conversation.id,
          user_id: ctx.user_id,
          type: "mute",
          reason: "Test",
          issued_by: ctx.admin_id,
          expires_at: past
        })

      assert {:ok, count} = Sanctions.expire_sanctions()
      assert count >= 1
    end
  end
end
