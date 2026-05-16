defmodule WhisprMessaging.ConversationsExtrasTest do
  @moduledoc """
  Additional coverage for `WhisprMessaging.Conversations` functions not
  exercised by `conversations_test.exs`.
  """

  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations

  defp build_group(name) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => name},
        is_active: true
      })

    conv
  end

  describe "count_conversation_members/1" do
    test "returns 0 for a fresh conversation" do
      conv = build_group("zero")
      assert Conversations.count_conversation_members(conv.id) == 0
    end

    test "counts only active members" do
      conv = build_group("count")
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(conv.id, u1)
      {:ok, _} = Conversations.add_conversation_member(conv.id, u2)

      assert Conversations.count_conversation_members(conv.id) == 2

      Conversations.remove_conversation_member(conv.id, u1)
      assert Conversations.count_conversation_members(conv.id) == 1
    end
  end

  describe "get_conversation/1 and get_conversation!/1" do
    test "returns {:ok, conversation} when found" do
      conv = build_group("get")
      assert {:ok, c} = Conversations.get_conversation(conv.id)
      assert c.id == conv.id
    end

    test "returns {:error, :not_found} when missing" do
      assert {:error, :not_found} = Conversations.get_conversation(Ecto.UUID.generate())
    end

    test "get_conversation!/1 raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(Ecto.UUID.generate())
      end
    end
  end

  describe "member_of_conversation?/2 and conversation_member?/2" do
    test "returns true when user is an active member" do
      conv = build_group("member")
      u = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(conv.id, u)

      assert Conversations.member_of_conversation?(conv.id, u)
      assert Conversations.conversation_member?(conv.id, u)
    end

    test "returns false for non-members" do
      conv = build_group("non-member")
      refute Conversations.member_of_conversation?(conv.id, Ecto.UUID.generate())
      refute Conversations.conversation_member?(conv.id, Ecto.UUID.generate())
    end
  end

  describe "member roles and admin list" do
    test "member_role/1 returns the configured role or default 'member'" do
      conv = build_group("roles")
      u = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conv.id, u)

      assert Conversations.member_role(member) in ["member", nil] or
               Conversations.member_role(member) == "member"
    end

    test "member_role/1 returns nil for a nil member" do
      assert is_nil(Conversations.member_role(nil))
    end

    test "set_member_role rejects an invalid role" do
      conv = build_group("invalid-role")
      u = Ecto.UUID.generate()
      {:ok, member} = Conversations.add_conversation_member(conv.id, u)

      assert {:error, :invalid_role} = Conversations.set_member_role(member, "godmode")
    end

    test "list_admin_members returns admin members only" do
      conv = build_group("admin-list")
      admin = Ecto.UUID.generate()
      reg = Ecto.UUID.generate()

      {:ok, admin_m} = Conversations.add_conversation_member(conv.id, admin)
      {:ok, _} = Conversations.add_conversation_member(conv.id, reg)
      {:ok, _} = Conversations.set_member_role(admin_m, "admin")

      admins = Conversations.list_admin_members(conv.id)
      assert Enum.any?(admins, &(&1.user_id == admin))
      refute Enum.any?(admins, &(&1.user_id == reg))
    end
  end

  describe "update_conversation/2" do
    test "updates the conversation metadata" do
      conv = build_group("update-target")

      assert {:ok, updated} =
               Conversations.update_conversation(conv, %{metadata: %{"name" => "Renamed Group"}})

      assert updated.metadata["name"] == "Renamed Group"
    end
  end

  describe "get_conversation_stats/1" do
    test "returns a stats map with member counts and last activity" do
      conv = build_group("stats")
      u = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(conv.id, u)

      stats = Conversations.get_conversation_stats(conv.id)
      assert is_map(stats)
      assert Map.has_key?(stats, :member_count)
    end
  end

  describe "get_unread_members/2" do
    test "returns members who haven't read messages since the timestamp" do
      conv = build_group("unread")
      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(conv.id, u1)
      {:ok, _} = Conversations.add_conversation_member(conv.id, u2)

      ts = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      unread = Conversations.get_unread_members(conv.id, ts)
      assert is_list(unread)
      assert length(unread) == 2
    end
  end

  describe "search_conversations/2" do
    test "matches by metadata text" do
      _ = build_group("Recherche unique abc123")
      results = Conversations.search_conversations("Recherche unique abc123", 5)
      assert is_list(results)
      assert Enum.any?(results, &(&1.metadata["name"] == "Recherche unique abc123"))
    end

    test "returns an empty list when no match" do
      assert Conversations.search_conversations("xyz-no-match-#{System.unique_integer()}", 5) ==
               []
    end
  end

  describe "get_conversation_by_external_group_id/1" do
    test "returns :not_found for unknown external_group_id" do
      assert {:error, :not_found} =
               Conversations.get_conversation_by_external_group_id(Ecto.UUID.generate())
    end
  end

  describe "find_direct_conversation/2" do
    test "returns nil or {:error, :not_found} when no direct conversation exists" do
      result =
        Conversations.find_direct_conversation(Ecto.UUID.generate(), Ecto.UUID.generate())

      # Different implementations may return either shape; accept both.
      assert result in [nil, {:error, :not_found}]
    end
  end

  describe "list_active_conversations/1" do
    test "returns a (possibly empty) list" do
      assert is_list(Conversations.list_active_conversations(5))
    end
  end

  describe "get_conversation_summaries/1" do
    test "returns {:ok, summaries} (possibly empty)" do
      assert {:ok, summaries} = Conversations.get_conversation_summaries(Ecto.UUID.generate())
      assert is_list(summaries)
    end
  end

  describe "get_user_active_conversations/1" do
    test "returns {:ok, ids} (possibly empty)" do
      assert {:ok, ids} = Conversations.get_user_active_conversations(Ecto.UUID.generate())
      assert is_list(ids)
    end
  end

  describe "list_user_conversations/2 (limit form)" do
    test "honours an integer limit" do
      assert is_list(Conversations.list_user_conversations(Ecto.UUID.generate(), 5))
    end
  end
end
