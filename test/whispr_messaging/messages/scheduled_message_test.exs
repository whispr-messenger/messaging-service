defmodule WhisprMessaging.Messages.ScheduledMessageTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.ScheduledMessage

  defp build_struct(attrs \\ %{}) do
    base = %ScheduledMessage{
      id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      sender_id: Ecto.UUID.generate(),
      message_type: "text",
      content: "hi",
      metadata: %{},
      client_random: 1,
      scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "pending"
    }

    struct(base, attrs)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "requires the mandatory fields" do
      cs = ScheduledMessage.changeset(%ScheduledMessage{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.conversation_id
      assert "can't be blank" in errors.sender_id
      assert "can't be blank" in errors.content
      assert "can't be blank" in errors.client_random
      assert "can't be blank" in errors.scheduled_at
    end

    test "rejects an invalid message_type" do
      future =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      cs =
        ScheduledMessage.changeset(%ScheduledMessage{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "voice",
          content: "hi",
          client_random: 1,
          scheduled_at: future
        })

      refute cs.valid?
      assert errors_on(cs).message_type |> Enum.any?(&(&1 =~ "is invalid"))
    end

    test "rejects past scheduled_at" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      cs =
        ScheduledMessage.changeset(%ScheduledMessage{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "hi",
          client_random: 1,
          scheduled_at: past
        })

      refute cs.valid?
      assert errors_on(cs).scheduled_at |> Enum.any?(&(&1 =~ "must be in the future"))
    end

    test "accepts valid input" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      cs =
        ScheduledMessage.changeset(%ScheduledMessage{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "hi",
          client_random: 1,
          scheduled_at: future
        })

      assert cs.valid?
    end
  end

  describe "lifecycle changesets" do
    test "cancel_changeset on pending succeeds" do
      cs = ScheduledMessage.cancel_changeset(build_struct(status: "pending"))
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "cancelled"
    end

    test "cancel_changeset on sent fails validation" do
      cs = ScheduledMessage.cancel_changeset(build_struct(status: "sent"))
      refute cs.valid?
    end

    test "mark_sent_changeset transitions to sent" do
      cs = ScheduledMessage.mark_sent_changeset(build_struct(status: "pending"))
      assert Ecto.Changeset.get_field(cs, :status) == "sent"
    end

    test "mark_failed_changeset transitions to failed" do
      cs = ScheduledMessage.mark_failed_changeset(build_struct(status: "pending"))
      assert Ecto.Changeset.get_field(cs, :status) == "failed"
    end
  end

  describe "queries" do
    test "due_messages_query returns an Ecto.Query" do
      assert %Ecto.Query{} = ScheduledMessage.due_messages_query()
    end

    test "pending_by_sender_query returns an Ecto.Query" do
      assert %Ecto.Query{} = ScheduledMessage.pending_by_sender_query(Ecto.UUID.generate())
    end
  end
end
