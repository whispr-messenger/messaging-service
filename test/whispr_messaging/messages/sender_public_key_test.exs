defmodule WhisprMessaging.Messages.SenderPublicKeyTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.SenderPublicKey

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  test "is invalid without user_id / public_key" do
    cs = SenderPublicKey.changeset(%SenderPublicKey{}, %{})
    refute cs.valid?
    errors = errors_on(cs)
    assert errors[:user_id] != nil
    assert errors[:public_key] != nil
  end

  test "is valid with both fields" do
    cs =
      SenderPublicKey.changeset(%SenderPublicKey{}, %{
        user_id: Ecto.UUID.generate(),
        public_key: Base.encode64(:crypto.strong_rand_bytes(32))
      })

    assert cs.valid?
  end
end
