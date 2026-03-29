defmodule WhisprMessaging.Repo.Migrations.AddExpiresAtToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :expires_at, :utc_datetime, null: true
    end

    # Index to efficiently query for expired messages in the cleanup worker
    create index(:messages, [:expires_at], where: "expires_at IS NOT NULL")
  end
end
