defmodule WhisprMessaging.Repo.Migrations.CreateConversationMembers do
  use Ecto.Migration

  def change do
    execute """
    CREATE TABLE IF NOT EXISTS conversation_members (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
      conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      user_id uuid NOT NULL,
      settings jsonb NOT NULL DEFAULT '{}',
      joined_at timestamp NOT NULL,
      last_read_at timestamp,
      is_active boolean NOT NULL DEFAULT true,
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL
    )
    """, ""

    # Indexes for conversation_members
    execute "CREATE UNIQUE INDEX IF NOT EXISTS conversation_members_conversation_id_user_id_index ON conversation_members(conversation_id, user_id)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_conversation_id ON conversation_members(conversation_id)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_user_id ON conversation_members(user_id)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_is_active ON conversation_members(is_active)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_joined_at ON conversation_members(joined_at)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_last_read_at ON conversation_members(last_read_at)", ""

    # Composite indexes for efficient queries
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_user_id_is_active ON conversation_members(user_id, is_active)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_conversation_id_is_active ON conversation_members(conversation_id, is_active)", ""
    execute "CREATE INDEX IF NOT EXISTS index_conversation_members_on_conversation_id_user_id_is_active ON conversation_members(conversation_id, user_id, is_active)", ""
  end
end