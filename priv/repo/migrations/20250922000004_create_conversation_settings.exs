defmodule WhisprMessaging.Repo.Migrations.CreateConversationSettings do
  use Ecto.Migration

  def change do
    create table(:conversation_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :settings, :map, null: false, default: "{}"

      timestamps()
    end

    # Indexes for conversation_settings
    create unique_index(:conversation_settings, [:conversation_id], name: :conversation_settings_conversation_id_index)
  end
end