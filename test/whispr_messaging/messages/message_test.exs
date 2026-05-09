defmodule WhisprMessaging.Messages.MessageTest do
  @moduledoc """
  Schema-level tests for the Message Ecto module: changesets, queries,
  and helper predicates.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.Message

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        conversation_id: Ecto.UUID.generate(),
        sender_id: Ecto.UUID.generate(),
        message_type: "text",
        content: "encrypted",
        client_random: System.unique_integer([:positive])
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "is valid with the required fields" do
      cs = Message.changeset(%Message{}, valid_attrs())
      assert cs.valid?
    end

    test "auto-fills sent_at when missing" do
      cs = Message.changeset(%Message{}, valid_attrs())
      assert %DateTime{} = cs.changes.sent_at || cs.data.sent_at
    end

    test "is invalid when required fields are missing" do
      cs = Message.changeset(%Message{}, %{})
      refute cs.valid?
    end

    test "rejects unknown message_type" do
      cs = Message.changeset(%Message{}, valid_attrs(%{message_type: "weird"}))
      refute cs.valid?
    end

    test "rejects content larger than the configured maximum" do
      huge = :binary.copy("a", 70_000)
      cs = Message.changeset(%Message{}, valid_attrs(%{content: huge}))
      refute cs.valid?
    end

    test "rejects non-binary content" do
      cs = Message.changeset(%Message{}, valid_attrs(%{content: %{not: "binary"}}))
      refute cs.valid?
    end

    test "rejects non-map metadata" do
      cs = Message.changeset(%Message{}, valid_attrs(%{metadata: "not a map"}))
      refute cs.valid?
    end

    test "rejects expires_at in the past" do
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      cs = Message.changeset(%Message{}, valid_attrs(%{expires_at: past}))
      refute cs.valid?
    end

    test "accepts expires_at in the future" do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      cs = Message.changeset(%Message{}, valid_attrs(%{expires_at: future}))
      assert cs.valid?
    end
  end

  describe "edit_changeset/3" do
    test "merges new metadata into the existing one" do
      msg = %Message{content: "old", metadata: %{"a" => 1}}
      cs = Message.edit_changeset(msg, "new", %{"b" => 2})
      assert cs.valid?
      assert cs.changes.content == "new"
      assert cs.changes.metadata == %{"a" => 1, "b" => 2}
      assert %DateTime{} = cs.changes.edited_at
    end

    test "rejects empty content" do
      cs = Message.edit_changeset(%Message{content: "old", metadata: %{}}, "")
      refute cs.valid?
    end
  end

  describe "delete_changeset/2" do
    test "marks the message deleted with the requested visibility" do
      cs = Message.delete_changeset(%Message{}, true)
      assert cs.changes == %{is_deleted: true, delete_for_everyone: true}
    end

    test "defaults to delete_for_everyone false" do
      cs = Message.delete_changeset(%Message{})
      assert cs.changes == %{is_deleted: true}
    end
  end

  describe "queries" do
    test "recent_messages_query supports a before timestamp" do
      assert %Ecto.Query{} = Message.recent_messages_query(Ecto.UUID.generate())
      assert %Ecto.Query{} = Message.recent_messages_query(Ecto.UUID.generate(), 10)

      assert %Ecto.Query{} =
               Message.recent_messages_query(Ecto.UUID.generate(), 10, DateTime.utc_now())
    end

    test "messages_after_query/2" do
      assert %Ecto.Query{} =
               Message.messages_after_query(Ecto.UUID.generate(), DateTime.utc_now())
    end

    test "undelivered_messages_query/1" do
      assert %Ecto.Query{} = Message.undelivered_messages_query(Ecto.UUID.generate())
    end

    test "search_messages_query/2" do
      assert %Ecto.Query{} = Message.search_messages_query(Ecto.UUID.generate(), "hello")
    end

    test "search_messages_query/3 applique un LIMIT par defaut a 50" do
      query = Message.search_messages_query(Ecto.UUID.generate(), "hello")
      assert %Ecto.Query{limit: %Ecto.Query.LimitExpr{params: [{50, :integer}]}} = query
    end

    test "search_messages_query/3 cap le LIMIT custom a 100" do
      query = Message.search_messages_query(Ecto.UUID.generate(), "hello", limit: 500)
      assert %Ecto.Query{limit: %Ecto.Query.LimitExpr{params: [{100, :integer}]}} = query
    end

    test "with_relations_query/1" do
      assert %Ecto.Query{} = Message.with_relations_query(Ecto.UUID.generate())
    end

    test "by_sender_query/2" do
      assert %Ecto.Query{} =
               Message.by_sender_query(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "unread_count_query supports nil and timestamped variants" do
      assert %Ecto.Query{} =
               Message.unread_count_query(Ecto.UUID.generate(), Ecto.UUID.generate(), nil)

      assert %Ecto.Query{} =
               Message.unread_count_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 DateTime.utc_now()
               )
    end
  end

  describe "create_*_message helpers" do
    test "create_text_message produces a text changeset" do
      cs =
        Message.create_text_message(Ecto.UUID.generate(), Ecto.UUID.generate(), "x", 1, %{
          "k" => "v"
        })

      assert cs.valid?
      assert cs.changes.message_type == "text"
    end

    test "create_media_message produces a media changeset" do
      cs =
        Message.create_media_message(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          "x",
          2,
          %{}
        )

      assert cs.valid?
      assert cs.changes.message_type == "media"
    end

    test "create_system_message produces a system changeset without a sender_id" do
      cs = Message.create_system_message(Ecto.UUID.generate(), "user joined", %{})
      # System messages have no sender_id by design
      refute Map.has_key?(cs.changes, :sender_id)
      assert cs.changes.message_type == "system"
    end

    test "create_system_message draws a random client_random in the int4 positive range" do
      cs = Message.create_system_message(Ecto.UUID.generate(), "joined", %{})
      assert is_integer(cs.changes.client_random)
      assert cs.changes.client_random >= 0
      # rester dans la plage PostgreSQL int4 signe positif
      assert cs.changes.client_random <= 2_147_483_647
    end

    test "create_system_message ne collide pas sous burst (1000 appels => 1000 valeurs distinctes)" do
      values =
        for _ <- 1..1000 do
          cs = Message.create_system_message(Ecto.UUID.generate(), "burst", %{})
          cs.changes.client_random
        end

      # crypto random sur 31 bits => collision quasi-nulle sur 1000 tirages
      assert MapSet.size(MapSet.new(values)) == 1000
    end
  end

  describe "generate_client_random/0" do
    test "renvoie un entier non-negatif dans la plage int4 positif" do
      for _ <- 1..200 do
        v = Message.generate_client_random()
        assert is_integer(v)
        assert v >= 0
        assert v <= 2_147_483_647
      end
    end
  end

  describe "type and state predicates" do
    test "text? / media? / system? distinguish message types" do
      assert Message.text?(%Message{message_type: "text"})
      refute Message.text?(%Message{message_type: "media"})
      assert Message.media?(%Message{message_type: "media"})
      assert Message.system?(%Message{message_type: "system"})
    end

    test "edited? reflects the edited_at field" do
      refute Message.edited?(%Message{edited_at: nil})
      assert Message.edited?(%Message{edited_at: DateTime.utc_now()})
    end

    test "deleted? reflects the is_deleted field" do
      assert Message.deleted?(%Message{is_deleted: true})
      refute Message.deleted?(%Message{is_deleted: false})
    end

    test "expired? returns false when expires_at is nil" do
      refute Message.expired?(%Message{expires_at: nil})
    end

    test "expired? returns true when expires_at is in the past" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second)
      assert Message.expired?(%Message{expires_at: past})
    end

    test "expired? returns false when expires_at is in the future" do
      future = DateTime.utc_now() |> DateTime.add(60, :second)
      refute Message.expired?(%Message{expires_at: future})
    end

    test "editable? rejects system, deleted, and old messages" do
      refute Message.editable?(%Message{message_type: "system"})
      refute Message.editable?(%Message{message_type: "text", is_deleted: true})

      old_sent =
        DateTime.utc_now() |> DateTime.add(-100_000, :second) |> DateTime.truncate(:second)

      refute Message.editable?(%Message{
               message_type: "text",
               is_deleted: false,
               sent_at: old_sent
             })

      assert Message.editable?(%Message{
               message_type: "text",
               is_deleted: false,
               sent_at: DateTime.utc_now()
             })
    end

    test "deletable? rejects already-deleted and old messages" do
      refute Message.deletable?(%Message{is_deleted: true})

      old_sent =
        DateTime.utc_now() |> DateTime.add(-200_000, :second) |> DateTime.truncate(:second)

      refute Message.deletable?(%Message{is_deleted: false, sent_at: old_sent})

      assert Message.deletable?(%Message{is_deleted: false, sent_at: DateTime.utc_now()})
    end
  end

  describe "metadata helpers" do
    test "get_metadata respects the default" do
      m = %Message{metadata: %{"a" => 1}}
      assert 1 == Message.get_metadata(m, "a")
      assert "fallback" == Message.get_metadata(m, "missing", "fallback")
    end

    test "put_metadata adds a new key without dropping existing ones" do
      m = %Message{metadata: %{"a" => 1}}
      m2 = Message.put_metadata(m, "b", 2)
      assert m2.metadata == %{"a" => 1, "b" => 2}
    end
  end

  describe "age_seconds/1" do
    test "returns a non-negative integer" do
      sent = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)
      assert Message.age_seconds(%Message{sent_at: sent}) >= 30
    end
  end
end
