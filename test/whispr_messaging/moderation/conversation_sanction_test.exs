defmodule WhisprMessaging.Moderation.ConversationSanctionTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Moderation.ConversationSanction

  describe "valid_types/0" do
    test "exposes the enum list" do
      assert "mute" in ConversationSanction.valid_types()
      assert "kick" in ConversationSanction.valid_types()
      assert "shadow_restrict" in ConversationSanction.valid_types()
    end
  end

  describe "changeset/2" do
    test "requires the mandatory fields" do
      cs = ConversationSanction.changeset(%ConversationSanction{}, %{})
      refute cs.valid?
    end

    test "rejects an unknown type" do
      cs =
        ConversationSanction.changeset(%ConversationSanction{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          type: "exile",
          reason: "test",
          issued_by: Ecto.UUID.generate()
        })

      refute cs.valid?
    end

    test "accepts a valid sanction" do
      cs =
        ConversationSanction.changeset(%ConversationSanction{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          type: "mute",
          reason: "spam",
          issued_by: Ecto.UUID.generate()
        })

      assert cs.valid?
    end
  end

  describe "lift_changeset/1" do
    test "sets active to false" do
      cs = ConversationSanction.lift_changeset(%ConversationSanction{active: true})
      assert Ecto.Changeset.get_field(cs, :active) == false
    end
  end

  describe "query builders" do
    test "active_for_conversation returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationSanction.active_for_conversation(Ecto.UUID.generate())
    end

    test "active_for_user_in_conversation returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationSanction.active_for_user_in_conversation(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "expired returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationSanction.expired()
    end
  end
end
