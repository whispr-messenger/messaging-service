defmodule WhisprMessaging.Conversations.ConversationSettingsTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Conversations.ConversationSettings

  defp build(settings \\ %{}) do
    %ConversationSettings{
      id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      settings: settings
    }
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "default_settings/0" do
    test "exposes expected keys" do
      d = ConversationSettings.default_settings()
      assert d["allow_editing"] == true
      assert d["max_file_size"] == 104_857_600
      assert is_list(d["allowed_file_types"])
    end
  end

  describe "changeset/2" do
    test "is invalid without conversation_id" do
      cs = ConversationSettings.changeset(%ConversationSettings{}, %{settings: %{}})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).conversation_id
    end

    test "accepts valid input" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{}
        })

      assert cs.valid?
    end

    test "rejects negative time limit" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"edit_time_limit" => -1}
        })

      refute cs.valid?
      assert errors_on(cs).settings |> Enum.any?(&(&1 =~ "non-negative integer"))
    end

    test "rejects unknown allowed_file_types" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"allowed_file_types" => ["image", "unknown"]}
        })

      refute cs.valid?
      assert errors_on(cs).settings |> Enum.any?(&(&1 =~ "invalid file types"))
    end

    test "rejects non-list allowed_file_types" do
      cs =
        ConversationSettings.changeset(%ConversationSettings{}, %{
          conversation_id: Ecto.UUID.generate(),
          settings: %{"allowed_file_types" => "image"}
        })

      refute cs.valid?
      assert errors_on(cs).settings |> Enum.any?(&(&1 =~ "must be a list"))
    end
  end

  describe "create_settings/2" do
    test "merges defaults with overrides" do
      cs = ConversationSettings.create_settings("c1", %{"allow_editing" => false})
      assert cs.valid?
      settings = Ecto.Changeset.get_field(cs, :settings)
      assert settings["allow_editing"] == false
      # Default kept
      assert settings["allow_deletion"] == true
    end
  end

  describe "get_setting/3 and put_setting/3" do
    test "get_setting falls back to default_settings" do
      assert ConversationSettings.get_setting(build(%{}), "allow_editing") == true
    end

    test "get_setting honours custom default when key truly unknown" do
      assert ConversationSettings.get_setting(build(%{}), "truly_unknown", :fallback) == :fallback
    end

    test "put_setting updates the map" do
      updated = ConversationSettings.put_setting(build(%{}), "key", 42)
      assert updated.settings["key"] == 42
    end
  end

  describe "editing/deletion windows" do
    test "editing_allowed? respects the time limit" do
      assert ConversationSettings.editing_allowed?(build(%{"edit_time_limit" => 60}), 30)
      refute ConversationSettings.editing_allowed?(build(%{"edit_time_limit" => 60}), 600)
    end

    test "editing_allowed? false when allow_editing is false" do
      refute ConversationSettings.editing_allowed?(build(%{"allow_editing" => false}), 1)
    end

    test "deletion_allowed? respects the time limit" do
      assert ConversationSettings.deletion_allowed?(build(%{"delete_time_limit" => 60}), 10)
      refute ConversationSettings.deletion_allowed?(build(%{"delete_time_limit" => 60}), 600)
    end

    test "deletion_allowed? false when allow_deletion is false" do
      refute ConversationSettings.deletion_allowed?(build(%{"allow_deletion" => false}), 1)
    end
  end

  describe "media / file helpers" do
    test "media_allowed? defaults to true" do
      assert ConversationSettings.media_allowed?(build(%{}))
    end

    test "max_file_size returns the configured value or default" do
      assert ConversationSettings.max_file_size(build(%{"max_file_size" => 42})) == 42
      assert ConversationSettings.max_file_size(build(%{})) == 104_857_600
    end

    test "file_type_allowed? respects the configured list" do
      assert ConversationSettings.file_type_allowed?(
               build(%{"allowed_file_types" => ["image"]}),
               "image"
             )

      refute ConversationSettings.file_type_allowed?(
               build(%{"allowed_file_types" => ["image"]}),
               "video"
             )
    end
  end

  describe "rate limit / privacy" do
    test "get_rate_limit returns the configured shape" do
      cfg =
        ConversationSettings.get_rate_limit(
          build(%{"rate_limit_enabled" => true, "max_messages_per_minute" => 5})
        )

      assert cfg.enabled == true
      assert cfg.max_messages_per_minute == 5
    end

    test "disappearing_messages_enabled? defaults false" do
      refute ConversationSettings.disappearing_messages_enabled?(build(%{}))

      assert ConversationSettings.disappearing_messages_enabled?(
               build(%{"disappearing_messages" => true})
             )
    end

    test "disappearing_timer returns the configured timer or default" do
      assert ConversationSettings.disappearing_timer(build(%{"disappearing_timer" => 60})) == 60
      assert ConversationSettings.disappearing_timer(build(%{})) == 604_800
    end

    test "delete_for_everyone_enabled? defaults to true" do
      assert ConversationSettings.delete_for_everyone_enabled?(build(%{}))
    end
  end

  describe "query builders and update changeset" do
    test "by_conversation_query returns an Ecto.Query" do
      assert %Ecto.Query{} = ConversationSettings.by_conversation_query(Ecto.UUID.generate())
    end

    test "update_settings_changeset stores the new settings map" do
      cs =
        ConversationSettings.update_settings_changeset(
          build(%{"allow_editing" => true}),
          %{"allow_editing" => false}
        )

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :settings) == %{"allow_editing" => false}
    end
  end
end
