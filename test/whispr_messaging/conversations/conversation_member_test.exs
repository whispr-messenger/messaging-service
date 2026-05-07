defmodule WhisprMessaging.Conversations.ConversationMemberTest do
  @moduledoc """
  Schema-level tests for ConversationMember: changesets, queries, helpers.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.ConversationMember

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        conversation_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate()
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "is valid with the required fields" do
      cs = ConversationMember.changeset(%ConversationMember{}, valid_attrs())
      assert cs.valid?
    end

    test "auto-fills joined_at when missing" do
      cs = ConversationMember.changeset(%ConversationMember{}, valid_attrs())
      assert %DateTime{} = cs.changes.joined_at || cs.data.joined_at
    end

    test "is invalid when required fields are missing" do
      cs = ConversationMember.changeset(%ConversationMember{}, %{})
      refute cs.valid?
    end

    test "rejects non-map settings" do
      cs =
        ConversationMember.changeset(
          %ConversationMember{},
          valid_attrs(%{settings: "not a map"})
        )

      refute cs.valid?
    end
  end

  describe "update_settings_changeset/2" do
    test "validates that settings are a map" do
      cs = ConversationMember.update_settings_changeset(%ConversationMember{}, %{"a" => 1})
      assert cs.valid?
      assert cs.changes.settings == %{"a" => 1}
    end
  end

  describe "mark_read_changeset/2" do
    test "uses the provided timestamp when given" do
      ts = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      cs = ConversationMember.mark_read_changeset(%ConversationMember{}, ts)
      assert cs.changes.last_read_at == ts
    end

    test "defaults to now when no timestamp is given" do
      cs = ConversationMember.mark_read_changeset(%ConversationMember{})
      assert %DateTime{} = cs.changes.last_read_at
    end
  end

  describe "deactivate_changeset/1" do
    test "marks the member inactive" do
      cs = ConversationMember.deactivate_changeset(%ConversationMember{is_active: true})
      assert cs.changes == %{is_active: false}
    end
  end

  describe "queries" do
    test "active_members_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationMember.active_members_query(Ecto.UUID.generate())
    end

    test "by_conversation_and_user_query/2 returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationMember.by_conversation_and_user_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "user_conversations_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationMember.user_conversations_query(Ecto.UUID.generate())
    end

    test "unread_members_query/2 returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationMember.unread_members_query(Ecto.UUID.generate(), DateTime.utc_now())
    end

    test "count_active_members_query/1 returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationMember.count_active_members_query(Ecto.UUID.generate())
    end
  end

  describe "default_settings/0" do
    test "returns the expected keys" do
      settings = ConversationMember.default_settings()
      assert settings["notifications"] == true
      assert Map.has_key?(settings, "sound_enabled")
      assert Map.has_key?(settings, "desktop_notifications")
      assert Map.has_key?(settings, "mobile_notifications")
      assert Map.has_key?(settings, "mention_notifications")
    end
  end

  describe "create_member/3" do
    test "builds a valid changeset" do
      cs =
        ConversationMember.create_member(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
          "role" => "admin"
        })

      assert cs.valid?
      assert cs.changes.settings == %{"role" => "admin"}
    end
  end

  describe "settings helpers" do
    test "get_setting and put_setting" do
      member = %ConversationMember{settings: %{"foo" => "bar"}}
      assert "bar" == ConversationMember.get_setting(member, "foo")
      assert "fallback" == ConversationMember.get_setting(member, "missing", "fallback")

      updated = ConversationMember.put_setting(member, "baz", 1)
      assert updated.settings == %{"foo" => "bar", "baz" => 1}
    end

    test "notifications_enabled? defaults to true" do
      assert ConversationMember.notifications_enabled?(%ConversationMember{settings: %{}})

      refute ConversationMember.notifications_enabled?(%ConversationMember{
               settings: %{"notifications" => false}
             })
    end
  end

  describe "has_unread_since?/2" do
    test "always true when last_read_at is nil" do
      assert ConversationMember.has_unread_since?(
               %ConversationMember{last_read_at: nil},
               DateTime.utc_now()
             )
    end

    test "true when last_read_at predates the threshold" do
      old = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      assert ConversationMember.has_unread_since?(
               %ConversationMember{last_read_at: old},
               DateTime.utc_now()
             )
    end

    test "false when last_read_at is more recent than the threshold" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -3600, :second) |> DateTime.truncate(:second)
      refute ConversationMember.has_unread_since?(%ConversationMember{last_read_at: now}, old)
    end
  end

  describe "active?/1 and membership_duration/1" do
    test "active? mirrors the is_active field" do
      assert ConversationMember.active?(%ConversationMember{is_active: true})
      refute ConversationMember.active?(%ConversationMember{is_active: false})
    end

    test "membership_duration returns a non-negative integer" do
      joined = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)
      duration = ConversationMember.membership_duration(%ConversationMember{joined_at: joined})
      assert duration >= 30
    end
  end
end
