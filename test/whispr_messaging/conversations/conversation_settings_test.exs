defmodule WhisprMessaging.Conversations.ConversationSettingsTest do
  @moduledoc """
  Schema-level tests for the ConversationSettings module.
  """

  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.ConversationSettings

  describe "default_settings/0" do
    test "exposes the expected feature flags" do
      defaults = ConversationSettings.default_settings()
      assert defaults["allow_editing"] == true
      assert defaults["allow_media"] == true
      assert defaults["encryption_enabled"] == true
      assert defaults["allowed_file_types"] == ["image", "video", "audio", "document"]
    end
  end

  describe "changeset/2" do
    test "is valid with required fields and a map of settings" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{}
        })

      assert cs.valid?
    end

    test "is invalid when required fields are missing" do
      cs = ConversationSettings.changeset(%ConversationSettings{}, %{})
      refute cs.valid?
    end

    test "rejects negative time limits" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"edit_time_limit" => -10}
        })

      refute cs.valid?
    end

    test "rejects invalid file types in allowed_file_types" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"allowed_file_types" => ["image", "weird"]}
        })

      refute cs.valid?
    end

    test "rejects allowed_file_types when not a list" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"allowed_file_types" => "image"}
        })

      refute cs.valid?
    end
  end

  describe "update_settings_changeset/2" do
    test "validates the new settings map" do
      cs =
        ConversationSettings.update_settings_changeset(
          %ConversationSettings{conversation_id: Ecto.UUID.generate()},
          %{"allow_editing" => false}
        )

      assert cs.valid?
      assert cs.changes.settings["allow_editing"] == false
    end

    test "rejects negative max_messages_per_minute" do
      cs =
        ConversationSettings.update_settings_changeset(
          %ConversationSettings{conversation_id: Ecto.UUID.generate()},
          %{"max_messages_per_minute" => -1}
        )

      refute cs.valid?
    end
  end

  describe "create_settings/2" do
    test "merges defaults with the provided settings" do
      cs = ConversationSettings.create_settings(Ecto.UUID.generate(), %{"allow_editing" => false})
      assert cs.valid?
      assert cs.changes.settings["allow_editing"] == false
      assert cs.changes.settings["allow_media"] == true
    end
  end

  describe "by_conversation_query/1" do
    test "returns an Ecto.Query" do
      assert %Ecto.Query{} =
               ConversationSettings.by_conversation_query(Ecto.UUID.generate())
    end
  end

  describe "get_setting and put_setting" do
    test "get_setting falls back to defaults when missing" do
      cs = %ConversationSettings{settings: %{}}
      assert true == ConversationSettings.get_setting(cs, "allow_editing")
    end

    test "get_setting returns the explicit value when present" do
      cs = %ConversationSettings{settings: %{"allow_editing" => false}}
      assert false == ConversationSettings.get_setting(cs, "allow_editing")
    end

    test "put_setting writes the new value" do
      cs = %ConversationSettings{settings: %{}}
      cs2 = ConversationSettings.put_setting(cs, "custom", 42)
      assert cs2.settings["custom"] == 42
    end
  end

  describe "feature predicates" do
    test "editing_allowed? respects flag and time limit" do
      cs = %ConversationSettings{settings: %{"allow_editing" => true, "edit_time_limit" => 60}}
      assert ConversationSettings.editing_allowed?(cs, 30)
      refute ConversationSettings.editing_allowed?(cs, 61)

      disabled = %ConversationSettings{settings: %{"allow_editing" => false}}
      refute ConversationSettings.editing_allowed?(disabled, 0)
    end

    test "deletion_allowed? respects flag and time limit" do
      cs = %ConversationSettings{settings: %{"allow_deletion" => true, "delete_time_limit" => 100}}
      assert ConversationSettings.deletion_allowed?(cs, 50)
      refute ConversationSettings.deletion_allowed?(cs, 200)
    end

    test "delete_for_everyone_enabled? defaults to true" do
      assert ConversationSettings.delete_for_everyone_enabled?(%ConversationSettings{settings: %{}})
    end

    test "media_allowed? mirrors the flag" do
      assert ConversationSettings.media_allowed?(%ConversationSettings{settings: %{}})

      refute ConversationSettings.media_allowed?(%ConversationSettings{
               settings: %{"allow_media" => false}
             })
    end

    test "max_file_size returns the configured number" do
      assert 1024 ==
               ConversationSettings.max_file_size(%ConversationSettings{
                 settings: %{"max_file_size" => 1024}
               })
    end

    test "file_type_allowed? respects the configured list" do
      cs = %ConversationSettings{settings: %{"allowed_file_types" => ["image"]}}
      assert ConversationSettings.file_type_allowed?(cs, "image")
      refute ConversationSettings.file_type_allowed?(cs, "video")
    end

    test "get_rate_limit exposes both fields" do
      cs = %ConversationSettings{settings: %{"max_messages_per_minute" => 5}}
      result = ConversationSettings.get_rate_limit(cs)
      assert result.enabled == true
      assert result.max_messages_per_minute == 5
    end

    test "disappearing_messages_enabled? and disappearing_timer" do
      refute ConversationSettings.disappearing_messages_enabled?(%ConversationSettings{
               settings: %{}
             })

      assert ConversationSettings.disappearing_messages_enabled?(%ConversationSettings{
               settings: %{"disappearing_messages" => true}
             })

      assert 60 ==
               ConversationSettings.disappearing_timer(%ConversationSettings{
                 settings: %{"disappearing_timer" => 60}
               })
    end
  end
end
