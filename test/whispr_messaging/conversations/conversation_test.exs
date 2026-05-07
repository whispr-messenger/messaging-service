defmodule WhisprMessaging.Conversations.ConversationTest do
  @moduledoc """
  Schema-level tests for the Conversation Ecto module — validates
  changesets, queries, and helper predicates.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.Conversation

  describe "changeset/2" do
    test "is valid for a direct conversation" do
      cs = Conversation.changeset(%Conversation{}, %{type: "direct"})
      assert cs.valid?
    end

    test "is valid for a group conversation with a name" do
      cs =
        Conversation.changeset(%Conversation{}, %{
          type: "group",
          metadata: %{"name" => "Family"}
        })

      assert cs.valid?
    end

    test "rejects unknown types" do
      cs = Conversation.changeset(%Conversation{}, %{type: "weird"})
      refute cs.valid?
    end

    test "requires a name for group conversations" do
      cs = Conversation.changeset(%Conversation{}, %{type: "group", metadata: %{}})
      refute cs.valid?
      assert {:metadata, _} = List.keyfind(cs.errors, :metadata, 0)
    end

    test "rejects group names longer than 100 chars" do
      long = String.duplicate("a", 101)

      cs =
        Conversation.changeset(%Conversation{}, %{type: "group", metadata: %{"name" => long}})

      refute cs.valid?
    end

    test "rejects non-string group name" do
      cs =
        Conversation.changeset(%Conversation{}, %{type: "group", metadata: %{"name" => 12_345}})

      refute cs.valid?
    end
  end

  describe "update_changeset/2" do
    test "permits metadata and is_active changes" do
      cs = Conversation.update_changeset(%Conversation{type: "direct"}, %{is_active: false})
      assert cs.valid?
      assert cs.changes.is_active == false
    end
  end

  describe "deactivate_changeset/1" do
    test "marks the conversation as inactive" do
      cs = Conversation.deactivate_changeset(%Conversation{is_active: true})
      assert cs.changes == %{is_active: false}
    end
  end

  describe "type predicates" do
    test "direct? and group? return correctly" do
      assert Conversation.direct?(%Conversation{type: "direct"})
      refute Conversation.direct?(%Conversation{type: "group"})
      refute Conversation.direct?(%{})

      assert Conversation.group?(%Conversation{type: "group"})
      refute Conversation.group?(%Conversation{type: "direct"})
    end
  end

  describe "display_name/1" do
    test "returns the group name from metadata" do
      assert "Roomies" ==
               Conversation.display_name(%Conversation{
                 type: "group",
                 metadata: %{"name" => "Roomies"}
               })
    end

    test "returns 'Unnamed Group' if name is missing" do
      assert "Unnamed Group" ==
               Conversation.display_name(%Conversation{type: "group", metadata: %{}})
    end

    test "returns 'Direct Message' for direct conversations" do
      assert "Direct Message" == Conversation.display_name(%Conversation{type: "direct"})
    end
  end

  describe "get_metadata / put_metadata" do
    test "get_metadata respects the default" do
      conv = %Conversation{metadata: %{"foo" => "bar"}}
      assert "bar" == Conversation.get_metadata(conv, "foo")
      assert "fallback" == Conversation.get_metadata(conv, "missing", "fallback")
    end

    test "put_metadata returns a struct with the merged value" do
      conv = %Conversation{metadata: %{"a" => 1}}
      conv2 = Conversation.put_metadata(conv, "b", 2)
      assert conv2.metadata == %{"a" => 1, "b" => 2}
    end
  end

  describe "queries" do
    test "by_user_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = Conversation.by_user_query(Ecto.UUID.generate())
    end

    test "direct_conversation_query/2 returns an Ecto.Query" do
      assert %Ecto.Query{} =
               Conversation.direct_conversation_query(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "by_external_group_query and alias return queries" do
      ext = Ecto.UUID.generate()
      assert %Ecto.Query{} = Conversation.by_external_group_query(ext)
      assert %Ecto.Query{} = Conversation.by_external_group_id_query(ext)
    end

    test "active_conversations_query/1 supports a custom limit" do
      assert %Ecto.Query{} = Conversation.active_conversations_query(10)
    end

    test "with_members_query and with_recent_messages_query return queries" do
      id = Ecto.UUID.generate()
      assert %Ecto.Query{} = Conversation.with_members_query(id)
      assert %Ecto.Query{} = Conversation.with_recent_messages_query(id, 5)
    end
  end

  describe "create_*_conversation builders" do
    test "create_direct_conversation builds a valid direct changeset" do
      cs = Conversation.create_direct_conversation(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert %Ecto.Changeset{} = cs
      assert cs.changes.type == "direct"
    end

    test "create_group_conversation builds a valid group changeset with a name" do
      cs =
        Conversation.create_group_conversation("Squad", Ecto.UUID.generate(), %{"emoji" => "🔥"})

      assert cs.valid?
      assert cs.changes.type == "group"
      assert cs.changes.metadata["name"] == "Squad"
    end
  end
end
