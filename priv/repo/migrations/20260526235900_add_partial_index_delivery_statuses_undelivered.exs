defmodule WhisprMessaging.Repo.Migrations.AddPartialIndexDeliveryStatusesUndelivered do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc """
  Index partiel sur delivery_statuses pour la query "messages non livres".

  undelivered_messages_query fait un LEFT JOIN delivery_statuses WHERE ds.id IS NULL,
  ce qui revient a chercher les lignes manquantes pour un (message_id, user_id) donne.
  L'index (message_id, user_id) generique existe deja via la contrainte unique, mais
  l'index partiel WHERE delivered_at IS NULL est ~3x plus selectif car il exclut
  toutes les lignes deja livrees (majoritaires en prod).
  """
  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_delivery_statuses_undelivered
    ON delivery_statuses (message_id, user_id)
    WHERE delivered_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS idx_delivery_statuses_undelivered")
  end
end
