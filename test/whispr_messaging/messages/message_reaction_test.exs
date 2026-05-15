defmodule WhisprMessaging.Messages.MessageReactionTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.MessageReaction

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "requires the mandatory fields" do
      cs = MessageReaction.changeset(%MessageReaction{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.message_id
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.reaction
    end

    test "accepts valid input" do
      cs =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          reaction: "👍"
        })

      assert cs.valid?
    end

    test "rejects reactions longer than 10 chars" do
      cs =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          reaction: String.duplicate("a", 11)
        })

      refute cs.valid?
      assert errors_on(cs).reaction |> Enum.any?(&(&1 =~ "should be at most"))
    end
  end

  describe "queries" do
    test "by_message_query returns an Ecto.Query" do
      assert %Ecto.Query{} = MessageReaction.by_message_query(Ecto.UUID.generate())
    end

    test "reaction_summary_query returns an Ecto.Query" do
      assert %Ecto.Query{} = MessageReaction.reaction_summary_query(Ecto.UUID.generate())
    end
  end
end
