defmodule WhisprMessaging.Messages.MessageSchemaTest do
  @moduledoc """
  Pure-function unit tests for `WhisprMessaging.Messages.Message` schema
  helpers (no database).
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.Message

  defp build(attrs \\ %{}) do
    base = %Message{
      id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      sender_id: Ecto.UUID.generate(),
      message_type: "text",
      content: "hello",
      metadata: %{},
      client_random: 42,
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
      is_deleted: false,
      delete_for_everyone: false
    }

    struct(base, attrs)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "type predicates" do
    test "text?/1" do
      assert Message.text?(build(message_type: "text"))
      refute Message.text?(build(message_type: "media"))
      refute Message.text?("not a struct")
    end

    test "media?/1" do
      assert Message.media?(build(message_type: "media"))
      refute Message.media?(build(message_type: "text"))
    end

    test "system?/1" do
      assert Message.system?(build(message_type: "system"))
      refute Message.system?(build(message_type: "text"))
    end
  end

  describe "lifecycle predicates" do
    test "edited?/1" do
      refute Message.edited?(build(edited_at: nil))

      assert Message.edited?(build(edited_at: DateTime.utc_now() |> DateTime.truncate(:second)))
    end

    test "deleted?/1" do
      assert Message.deleted?(build(is_deleted: true))
      refute Message.deleted?(build(is_deleted: false))
    end

    test "expired?/1 returns false when expires_at is nil" do
      refute Message.expired?(build(expires_at: nil))
    end

    test "expired?/1 returns true when expires_at is past" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert Message.expired?(build(expires_at: past))
    end

    test "expired?/1 returns false when expires_at is future" do
      future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
      refute Message.expired?(build(expires_at: future))
    end
  end

  describe "metadata helpers" do
    test "get_metadata/3 returns the value or default" do
      m = build(metadata: %{"k" => "v"})
      assert Message.get_metadata(m, "k") == "v"
      assert Message.get_metadata(m, "missing", :d) == :d
    end

    test "put_metadata/3 stores a key" do
      updated = Message.put_metadata(build(metadata: %{}), "k", "v")
      assert updated.metadata == %{"k" => "v"}
    end
  end

  describe "age and editability" do
    test "age_seconds is non-negative" do
      assert Message.age_seconds(build()) >= 0
    end

    test "editable?: system messages are not editable" do
      refute Message.editable?(build(message_type: "system"))
    end

    test "editable?: deleted messages are not editable" do
      refute Message.editable?(build(is_deleted: true))
    end

    test "editable?: fresh text message is editable" do
      assert Message.editable?(build(message_type: "text"))
    end

    test "editable?: old text message is not editable" do
      old = DateTime.utc_now() |> DateTime.add(-90_000, :second) |> DateTime.truncate(:second)
      refute Message.editable?(build(message_type: "text", sent_at: old))
    end
  end

  describe "deletable?/1" do
    test "deleted messages are not deletable again" do
      refute Message.deletable?(build(is_deleted: true))
    end

    test "fresh message is deletable" do
      assert Message.deletable?(build())
    end

    test "old message is not deletable" do
      old = DateTime.utc_now() |> DateTime.add(-200_000, :second) |> DateTime.truncate(:second)
      refute Message.deletable?(build(sent_at: old))
    end
  end

  describe "changeset/2" do
    test "is invalid without required fields" do
      cs = Message.changeset(%Message{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.conversation_id
      assert "can't be blank" in errors.sender_id
      assert "can't be blank" in errors.message_type
      assert "can't be blank" in errors.client_random
    end

    test "rejects invalid message_type" do
      cs =
        Message.changeset(%Message{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "voice",
          content: "x",
          client_random: 1
        })

      refute cs.valid?
      assert errors_on(cs).message_type |> Enum.any?(&(&1 =~ "is invalid"))
    end

    test "rejects expires_at in the past" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      cs =
        Message.changeset(%Message{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "x",
          client_random: 1,
          expires_at: past
        })

      refute cs.valid?
      assert "must be in the future" in errors_on(cs).expires_at
    end

    test "accepts a valid input" do
      cs =
        Message.changeset(%Message{}, %{
          conversation_id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "x",
          client_random: 1
        })

      assert cs.valid?
    end
  end

  describe "edit_changeset/3 and delete_changeset/2" do
    test "edit_changeset sets edited_at and new content" do
      m = build()
      cs = Message.edit_changeset(m, "new content")
      assert Ecto.Changeset.get_field(cs, :content) == "new content"
      assert Ecto.Changeset.get_field(cs, :edited_at) != nil
    end

    test "delete_changeset/1 marks soft-deleted" do
      cs = Message.delete_changeset(build())
      assert Ecto.Changeset.get_field(cs, :is_deleted) == true
      assert Ecto.Changeset.get_field(cs, :delete_for_everyone) == false
    end

    test "delete_changeset/2 marks delete_for_everyone" do
      cs = Message.delete_changeset(build(), true)
      assert Ecto.Changeset.get_field(cs, :is_deleted) == true
      assert Ecto.Changeset.get_field(cs, :delete_for_everyone) == true
    end
  end

  describe "create helpers" do
    test "create_text_message/4 builds a changeset" do
      cs = Message.create_text_message(Ecto.UUID.generate(), Ecto.UUID.generate(), "hi", 99)
      assert %Ecto.Changeset{} = cs
      assert Ecto.Changeset.get_field(cs, :message_type) == "text"
    end

    test "create_media_message/5 builds a media changeset" do
      cs =
        Message.create_media_message(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          "encrypted",
          100,
          %{"x" => 1}
        )

      assert Ecto.Changeset.get_field(cs, :message_type) == "media"
      assert Ecto.Changeset.get_field(cs, :metadata) == %{"x" => 1}
    end

    test "create_system_message/3 builds a system changeset with nil sender_id" do
      cs = Message.create_system_message(Ecto.UUID.generate(), "joined")
      assert Ecto.Changeset.get_field(cs, :message_type) == "system"
    end
  end

  describe "query builders" do
    test "recent_messages_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Message.recent_messages_query(Ecto.UUID.generate())
      assert %Ecto.Query{} = Message.recent_messages_query(Ecto.UUID.generate(), 10)

      assert %Ecto.Query{} =
               Message.recent_messages_query(Ecto.UUID.generate(), 5, DateTime.utc_now())
    end

    test "messages_after_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               Message.messages_after_query(Ecto.UUID.generate(), DateTime.utc_now())
    end

    test "undelivered_messages_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Message.undelivered_messages_query(Ecto.UUID.generate())
    end

    test "search_messages_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               Message.search_messages_query(Ecto.UUID.generate(), "search term")
    end

    test "with_relations_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Message.with_relations_query(Ecto.UUID.generate())
    end

    test "by_sender_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               Message.by_sender_query(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "unread_count_query/3 honours last_read_at" do
      assert %Ecto.Query{} =
               Message.unread_count_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 nil
               )

      assert %Ecto.Query{} =
               Message.unread_count_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 DateTime.utc_now()
               )
    end
  end
end
