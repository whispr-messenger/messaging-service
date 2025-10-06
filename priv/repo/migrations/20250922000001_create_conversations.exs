defmodule WhisprMessaging.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    # Enable UUID extension
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"", ""

    # Create conversations table
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :type, :string, null: false
      add :external_group_id, :binary_id, null: true
      add :metadata, :map, null: false, default: "{}"
      add :is_active, :boolean, null: false, default: true

      timestamps()
    end

    # Indexes for conversations
    create index(:conversations, [:type])
    create unique_index(:conversations, [:external_group_id], name: :conversations_external_group_id_index)
    create unique_index(:conversations, [:external_group_id], name: :conversations_external_group_id_index)
    create index(:conversations, [:created_at])
    create index(:conversations, [:updated_at])
    create index(:conversations, [:is_active])

    # Create conversation_members table
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
    create index(:conversation_members, [:last_read_at])
    create index(:conversation_members, [:is_active])

    # Create conversation_settings table
    create table(:conversation_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :settings, :map, null: false, default: "{}"

      timestamps()
    end

    # Unique index for conversation_settings
    create unique_index(:conversation_settings, [:conversation_id])
  end
end
