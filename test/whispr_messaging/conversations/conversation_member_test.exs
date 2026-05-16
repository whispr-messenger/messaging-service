defmodule WhisprMessaging.Conversations.ConversationMemberTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.ConversationMember

  defp build(attrs \\ %{}) do
    base = %ConversationMember{
      id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      settings: %{},
      joined_at: DateTime.utc_now() |> DateTime.truncate(:second),
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
    test "requires conversation_id and user_id" do
      cs = ConversationMember.changeset(%ConversationMember{}, %{})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).conversation_id
      assert "can't be blank" in errors_on(cs).user_id
    end

    test "fills joined_at when missing" do
      cs =
        ConversationMember.changeset(%ConversationMember{}, %{
          conversation_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate()
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :joined_at) != nil
    end
  end

  describe "update_settings_changeset/2" do
    test "stores the new settings map" do
      member = build()
      cs = ConversationMember.update_settings_changeset(member, %{"foo" => "bar"})
      assert Ecto.Changeset.get_field(cs, :settings) == %{"foo" => "bar"}
    end
  end

  describe "mark_read_changeset/2" do
    test "uses the provided timestamp" do
      ts = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      cs = ConversationMember.mark_read_changeset(build(), ts)
      assert Ecto.Changeset.get_field(cs, :last_read_at) == ts
    end

    test "defaults to now when no timestamp is given" do
      cs = ConversationMember.mark_read_changeset(build())
      assert %DateTime{} = Ecto.Changeset.get_field(cs, :last_read_at)
    end
  end

  describe "deactivate_changeset/1" do
    test "sets is_active to false" do
      cs = ConversationMember.deactivate_changeset(build(is_active: true))
      assert Ecto.Changeset.get_field(cs, :is_active) == false
    end
  end

  describe "create_member/3" do
    test "builds a valid changeset with default settings" do
      conv_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      cs = ConversationMember.create_member(conv_id, user_id)
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :conversation_id) == conv_id
      assert Ecto.Changeset.get_field(cs, :user_id) == user_id
    end
  end

  describe "default_settings/0" do
    test "returns the expected keys" do
      defaults = ConversationMember.default_settings()
      assert defaults["notifications"] == true
      assert defaults["desktop_notifications"] == true
      assert defaults["sound_enabled"] == true
    end
  end

  describe "get_setting/3 and put_setting/3" do
    test "get_setting returns the value or default" do
      member = build(settings: %{"k" => "v"})
      assert ConversationMember.get_setting(member, "k") == "v"
      assert ConversationMember.get_setting(member, "missing", :d) == :d
    end

    test "put_setting updates the settings map" do
      member = build(settings: %{})
      updated = ConversationMember.put_setting(member, "key", "value")
      assert updated.settings == %{"key" => "value"}
    end
  end

  describe "notifications_enabled?/1" do
    test "defaults to true when not set" do
      assert ConversationMember.notifications_enabled?(build(settings: %{}))
    end

    test "respects an explicit false" do
      refute ConversationMember.notifications_enabled?(
               build(settings: %{"notifications" => false})
             )
    end
  end

  describe "has_unread_since?/2" do
    test "true when last_read_at is nil" do
      assert ConversationMember.has_unread_since?(build(), DateTime.utc_now())
    end

    test "true when last_read_at is before the reference timestamp" do
      ref = DateTime.utc_now() |> DateTime.truncate(:second)
      last = DateTime.add(ref, -60, :second)
      assert ConversationMember.has_unread_since?(build(last_read_at: last), ref)
    end

    test "false when last_read_at is after the reference timestamp" do
      ref = DateTime.utc_now() |> DateTime.truncate(:second)
      last = DateTime.add(ref, 60, :second)
      refute ConversationMember.has_unread_since?(build(last_read_at: last), ref)
    end
  end

  describe "active?/1" do
    test "tracks the is_active field" do
      assert ConversationMember.active?(build(is_active: true))
      refute ConversationMember.active?(build(is_active: false))
    end
  end

  describe "membership_duration/1" do
    test "returns a non-negative integer number of seconds" do
      joined = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      duration = ConversationMember.membership_duration(build(joined_at: joined))
      assert duration >= 3600
    end
  end

  describe "query builders" do
    test "active_members_query returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationMember.active_members_query(Ecto.UUID.generate())
    end

    test "by_conversation_and_user_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationMember.by_conversation_and_user_query(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate()
               )
    end

    test "user_conversations_query returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationMember.user_conversations_query(Ecto.UUID.generate())
    end

    test "unread_members_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationMember.unread_members_query(
                 Ecto.UUID.generate(),
                 DateTime.utc_now()
               )
    end

    test "count_active_members_query returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationMember.count_active_members_query(Ecto.UUID.generate())
    end
  end
end
