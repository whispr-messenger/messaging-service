defmodule WhisprMessaging.Messages.PinnedMessageTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.PinnedMessage

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  describe "changeset/2" do
    test "fills pinned_at when missing" do
      cs =
        PinnedMessage.changeset(%PinnedMessage{}, %{
          message_id: Ecto.UUID.generate(),
          conversation_id: Ecto.UUID.generate(),
          pinned_by: Ecto.UUID.generate()
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :pinned_at) != nil
    end

    test "is invalid without the required fields" do
      cs = PinnedMessage.changeset(%PinnedMessage{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert errors[:message_id] != nil
      assert errors[:conversation_id] != nil
      assert errors[:pinned_by] != nil
    end
  end

  describe "by_conversation_query/1" do
    test "returns an Ecto.Query" do
      assert %Ecto.Query{} = PinnedMessage.by_conversation_query(Ecto.UUID.generate())
    end
  end
end
