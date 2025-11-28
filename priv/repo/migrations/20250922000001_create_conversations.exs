defmodule WhisprMessaging.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    # Enable UUID extension
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"", ""

    # Create conversations table only - other tables are in separate migrations
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
    create unique_index(:conversations, [:external_group_id], name: :conversations_external_group_id_index, where: "external_group_id IS NOT NULL")
    create index(:conversations, [:inserted_at])
    create index(:conversations, [:updated_at])
    create index(:conversations, [:is_active])
  end
end