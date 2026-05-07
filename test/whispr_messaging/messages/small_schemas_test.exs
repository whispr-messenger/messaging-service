defmodule WhisprMessaging.Messages.SmallSchemasTest do
  @moduledoc """
  Schema-level tests for the smaller message-related Ecto schemas:
  MessageDraft, MessageReaction and PinnedMessage.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.{MessageDraft, MessageReaction, PinnedMessage}

  describe "MessageDraft.changeset/2" do
    test "is valid with required fields" do
      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: "encrypted draft"
        })

      assert cs.valid?
    end

    test "is invalid when required fields are missing" do
      cs = MessageDraft.changeset(%MessageDraft{}, %{})
      refute cs.valid?
    end

    test "rejects content that exceeds the size limit" do
      huge = :binary.copy("x", 100_000)

      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: huge
        })

      refute cs.valid?
    end

    test "rejects non-binary content" do
      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: 123
        })

      refute cs.valid?
    end

    test "rejects non-map metadata" do
      cs =
        MessageDraft.changeset(%MessageDraft{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          content: "x",
          metadata: "not a map"
        })

      refute cs.valid?
    end
  end

  describe "MessageDraft queries" do
    test "by_conversation_and_user_query/2 returns an Ecto.Query" do
      assert %Ecto.Query{} =
               MessageDraft.by_conversation_and_user_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "by_user_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = MessageDraft.by_user_query(Ecto.UUID.generate())
    end
  end

  describe "MessageReaction.changeset/2" do
    test "is valid with the required fields" do
      cs =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          reaction: ":heart:"
        })

      assert cs.valid?
    end

    test "rejects reactions longer than 10 characters" do
      cs =
        MessageReaction.changeset(%MessageReaction{}, %{
          message_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          reaction: String.duplicate("a", 11)
        })

      refute cs.valid?
    end

    test "is invalid when required fields are missing" do
      cs = MessageReaction.changeset(%MessageReaction{}, %{})
      refute cs.valid?
    end
  end

  describe "MessageReaction queries" do
    test "by_message_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = MessageReaction.by_message_query(Ecto.UUID.generate())
    end

    test "reaction_summary_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = MessageReaction.reaction_summary_query(Ecto.UUID.generate())
    end
  end

  describe "PinnedMessage.changeset/2" do
    test "is valid with the required fields and auto-fills pinned_at" do
      cs =
        PinnedMessage.changeset(%PinnedMessage{}, %{
          message_id: Ecto.UUID.generate(),
          conversation_id: Ecto.UUID.generate(),
          pinned_by: Ecto.UUID.generate()
        })

      assert cs.valid?
      assert %NaiveDateTime{} = cs.changes.pinned_at
    end

    test "is invalid when required fields are missing" do
      cs = PinnedMessage.changeset(%PinnedMessage{}, %{})
      refute cs.valid?
    end

    test "respects an explicit pinned_at" do
      ts = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      cs =
        PinnedMessage.changeset(%PinnedMessage{}, %{
          message_id: Ecto.UUID.generate(),
          conversation_id: Ecto.UUID.generate(),
          pinned_by: Ecto.UUID.generate(),
          pinned_at: ts
        })

      assert cs.changes.pinned_at == ts
    end
  end

  describe "PinnedMessage.by_conversation_query/1" do
    test "returns an Ecto.Query" do
      assert %Ecto.Query{} = PinnedMessage.by_conversation_query(Ecto.UUID.generate())
    end
  end
end
