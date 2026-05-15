defmodule WhisprMessaging.Messages.UserMessageDeletionTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.UserMessageDeletion

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  test "is invalid without user_id / message_id" do
    cs = UserMessageDeletion.changeset(%{})
    refute cs.valid?
    errors = errors_on(cs)
    assert errors[:user_id] != nil
    assert errors[:message_id] != nil
  end

  test "is valid with both ids" do
    cs =
      UserMessageDeletion.changeset(%{
        user_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate()
      })

    assert cs.valid?
  end

  test "accepts an existing struct as first argument" do
    cs =
      UserMessageDeletion.changeset(%UserMessageDeletion{}, %{
        user_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate()
      })

    assert cs.valid?
  end
end
