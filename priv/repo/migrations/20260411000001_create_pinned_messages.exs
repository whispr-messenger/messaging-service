defmodule WhisprMessaging.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pinned_by, :binary_id, null: false
      add :pinned_at, :naive_datetime, null: false

      timestamps()
    end

    create unique_index(:pinned_messages, [:message_id])
    create index(:pinned_messages, [:conversation_id])
  end
end
