defmodule WhisprMessaging.Repo.Migrations.CreateConversationSanctions do
  use Ecto.Migration

  def change do
    create table(:conversation_sanctions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :type, :string, null: false
      add :reason, :text, null: false
      add :issued_by, :binary_id, null: false
      add :expires_at, :utc_datetime
      add :active, :boolean, default: true, null: false

      timestamps(updated_at: false)
    end

    create index(:conversation_sanctions, [:conversation_id, :user_id, :active])
    create index(:conversation_sanctions, [:user_id])
    create index(:conversation_sanctions, [:expires_at], where: "active = true AND expires_at IS NOT NULL")
  end
end
