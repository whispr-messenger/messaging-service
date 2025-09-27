defmodule WhisprMessaging.Repo.Migrations.CreateConversationMembers do
  use Ecto.Migration

  def change do
    create table(:conversation_members, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :settings, :map, null: false, default: "{}"
      add :joined_at, :utc_datetime, null: false
      add :last_read_at, :utc_datetime, null: true
      add :is_active, :boolean, null: false, default: true

      timestamps()
    end

    # Indexes for conversation_members
    create unique_index(:conversation_members, [:conversation_id, :user_id], name: :conversation_members_conversation_id_user_id_index)
    create index(:conversation_members, [:conversation_id])
    create index(:conversation_members, [:user_id])
    create index(:conversation_members, [:is_active])
    create index(:conversation_members, [:joined_at])
    create index(:conversation_members, [:last_read_at])

    # Composite indexes for efficient queries
    create index(:conversation_members, [:user_id, :is_active])
    create index(:conversation_members, [:conversation_id, :is_active])
    create index(:conversation_members, [:conversation_id, :user_id, :is_active])
  end
end