defmodule WhisprMessaging.Repo.Migrations.CreateConversationSettings do
  use Ecto.Migration

  def change do
    execute """
    CREATE TABLE IF NOT EXISTS conversation_settings (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
      conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      settings jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamp(0) NOT NULL,
      updated_at timestamp(0) NOT NULL
    )
    """, ""

    # Indexes for conversation_settings
    execute "CREATE UNIQUE INDEX IF NOT EXISTS conversation_settings_conversation_id_index ON conversation_settings(conversation_id)", ""
  end
end