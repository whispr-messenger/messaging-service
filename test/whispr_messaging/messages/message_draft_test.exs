defmodule WhisprMessaging.Messages.MessageDraftTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.MessageDraft

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "requires conversation_id, user_id, content" do
      cs = MessageDraft.changeset(%MessageDraft{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.conversation_id
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.content
    end

    test "accepts a valid input" do
      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: "hi",
          metadata: %{}
        })

      assert cs.valid?
    end

    test "rejects oversized content" do
      big = :crypto.strong_rand_bytes(70_000)

      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: big
        })

      refute cs.valid?
      assert errors_on(cs).content |> Enum.any?(&(&1 =~ "exceeds maximum size"))
    end
  end
end
