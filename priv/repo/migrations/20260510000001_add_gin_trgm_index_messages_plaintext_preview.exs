defmodule WhisprMessaging.Repo.Migrations.AddGinTrgmIndexMessagesPlaintextPreview do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Nécessite l'extension pg_trgm pour les recherches ILIKE performantes
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS messages_plaintext_preview_trgm_idx
    ON messages
    USING gin ((metadata->>'plaintext_preview') gin_trgm_ops)
    WHERE metadata->>'plaintext_preview' IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS messages_plaintext_preview_trgm_idx")
  end
end
