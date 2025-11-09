defmodule WhisprMessaging.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    # Enable UUID extension
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"", ""

    # Create conversations table
    execute """
    CREATE TABLE IF NOT EXISTS conversations (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
      type varchar NOT NULL,
      external_group_id uuid,
      metadata jsonb NOT NULL DEFAULT '{}',
      is_active boolean NOT NULL DEFAULT true,
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL
    )
    """, ""

    # Create indexes for conversations
    execute "CREATE INDEX IF NOT EXISTS index_conversations_on_type ON conversations(type)", ""
    execute "CREATE UNIQUE INDEX IF NOT EXISTS conversations_external_group_id_index ON conversations(external_group_id)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversations_on_inserted_at ON conversations(inserted_at)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversations_on_updated_at ON conversations(updated_at)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversations_on_is_active ON conversations(is_active)", ""
  end
end