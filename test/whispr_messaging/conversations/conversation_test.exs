defmodule WhisprMessaging.Conversations.ConversationTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.Conversation

  defp build(attrs \\ %{}) do
    base = %Conversation{
      id: Ecto.UUID.generate(),
      type: "direct",
      metadata: %{},
      is_active: true
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

  describe "changeset/2" do
    test "is invalid without :type" do
      cs = Conversation.changeset(%Conversation{}, %{})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).type
    end

    test "rejects an invalid type" do
      cs = Conversation.changeset(%Conversation{}, %{type: "broadcast"})
      refute cs.valid?
      assert errors_on(cs).type |> Enum.any?(&(&1 =~ "is invalid"))
    end

    test "validates group metadata requires a name" do
      cs = Conversation.changeset(%Conversation{}, %{type: "group", metadata: %{}})
      refute cs.valid?
      assert errors_on(cs).metadata |> Enum.any?(&(&1 =~ "must have a name"))
    end

    test "validates group name is a string" do
      cs = Conversation.changeset(%Conversation{}, %{type: "group", metadata: %{"name" => 42}})
      refute cs.valid?
      assert errors_on(cs).metadata |> Enum.any?(&(&1 =~ "must be a string"))
    end

    test "rejects group name exceeding 100 chars" do
      cs =
        Conversation.changeset(%Conversation{}, %{
          type: "group",
          metadata: %{"name" => String.duplicate("a", 101)}
        })

      refute cs.valid?
      assert errors_on(cs).metadata |> Enum.any?(&(&1 =~ "cannot exceed 100"))
    end

    test "direct conversations require no name in metadata" do
      cs = Conversation.changeset(%Conversation{}, %{type: "direct", metadata: %{}})
      assert cs.valid?
    end
  end

  describe "invite_changeset/2" do
    test "casts invite_token and invite_expires_at" do
      uuid = Ecto.UUID.generate()
      expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      cs =
        Conversation.invite_changeset(%Conversation{}, %{
          invite_token: uuid,
          invite_expires_at: expires
        })

      assert get_field(cs, :invite_token) == uuid
    end
  end

  describe "update_changeset/2" do
    test "updates metadata and is_active" do
      conv = build(type: "group", metadata: %{"name" => "old"})

      cs =
        Conversation.update_changeset(conv, %{
          metadata: %{"name" => "new"},
          is_active: false
        })

      assert cs.valid?
      assert get_field(cs, :is_active) == false
    end
  end

  describe "deactivate_changeset/1" do
    test "sets is_active to false" do
      cs = Conversation.deactivate_changeset(build())
      assert get_field(cs, :is_active) == false
    end
  end

  describe "predicates" do
    test "direct?/1 and group?/1" do
      assert Conversation.direct?(build(type: "direct"))
      refute Conversation.direct?(build(type: "group"))
      assert Conversation.group?(build(type: "group"))
      refute Conversation.group?(build(type: "direct"))
      refute Conversation.direct?(:not_a_struct)
      refute Conversation.group?(:not_a_struct)
    end
  end

  describe "display_name/1" do
    test "group with a name in metadata" do
      assert Conversation.display_name(build(type: "group", metadata: %{"name" => "Team"})) ==
               "Team"
    end

    test "group without a name in metadata" do
      assert Conversation.display_name(build(type: "group", metadata: %{})) == "Unnamed Group"
    end

    test "direct conversation" do
      assert Conversation.display_name(build(type: "direct")) == "Direct Message"
    end
  end

  describe "metadata helpers" do
    test "get_metadata/3 returns the value or default" do
      conv = build(metadata: %{"k" => "v"})
      assert Conversation.get_metadata(conv, "k") == "v"
      assert Conversation.get_metadata(conv, "missing", :fallback) == :fallback
    end

    test "put_metadata/3 inserts/replaces a key" do
      updated = Conversation.put_metadata(build(metadata: %{}), "key", "value")
      assert updated.metadata == %{"key" => "value"}
    end
  end

  describe "create helpers" do
    test "create_direct_conversation/3 builds a changeset" do
      cs = Conversation.create_direct_conversation("u1", "u2", %{"x" => 1})
      assert %Ecto.Changeset{} = cs
      assert get_field(cs, :type) == "direct"
      assert get_field(cs, :metadata) == %{"x" => 1}
    end

    test "create_group_conversation/3 builds a changeset including the name" do
      cs = Conversation.create_group_conversation("Team", "ext-1", %{"extra" => true})
      assert %Ecto.Changeset{} = cs
      assert get_field(cs, :type) == "group"
      assert get_field(cs, :external_group_id) == "ext-1"
      meta = get_field(cs, :metadata)
      assert meta["name"] == "Team"
      assert meta["extra"] == true
    end
  end

  defp get_field(cs, key) do
    Ecto.Changeset.get_field(cs, key)
  end

  describe "query builders" do
    test "by_user_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.by_user_query(Ecto.UUID.generate())
    end

    test "direct_conversation_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               Conversation.direct_conversation_query(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "by_external_group_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.by_external_group_query(Ecto.UUID.generate())
    end

    test "by_external_group_id_query is an alias of by_external_group_query" do
      assert %Ecto.Query{} = Conversation.by_external_group_id_query(Ecto.UUID.generate())
    end

    test "active_conversations_query/0 returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.active_conversations_query()
    end

    test "active_conversations_query/1 honours the limit argument" do
      assert %Ecto.Query{} = Conversation.active_conversations_query(10)
    end

    test "with_members_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.with_members_query(Ecto.UUID.generate())
    end

    test "with_recent_messages_query returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.with_recent_messages_query(Ecto.UUID.generate())
      assert %Ecto.Query{} = Conversation.with_recent_messages_query(Ecto.UUID.generate(), 20)
    end
  end
end
