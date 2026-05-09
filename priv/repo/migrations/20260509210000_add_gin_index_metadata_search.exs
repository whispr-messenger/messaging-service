defmodule WhisprMessaging.Repo.Migrations.AddGinIndexMetadataSearch do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Indexes GIN pour eviter les seq-scan sur ILIKE metadata::text
  # cf WHISPR-1419 - search_user_conversations + search_messages_query
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_metadata_gin_idx
    ON messages USING gin (metadata jsonb_path_ops)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS conversations_metadata_gin_idx
    ON conversations USING gin (metadata jsonb_path_ops)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS messages_metadata_gin_idx")
    execute("DROP INDEX CONCURRENTLY IF EXISTS conversations_metadata_gin_idx")
  end
end
