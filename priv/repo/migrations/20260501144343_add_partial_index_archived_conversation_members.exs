defmodule WhisprMessaging.Repo.Migrations.AddPartialIndexArchivedConversationMembers do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS conversation_members_user_archived_idx
    ON conversation_members (user_id)
    WHERE is_active = true AND ((settings->>'is_archived')::boolean = true)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS conversation_members_user_archived_idx")
  end
end
