defmodule WhisprMessaging.Repo.Migrations.CreateUserMessageDeletions do
  use Ecto.Migration

  def change do
    create table(:user_message_deletions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false

      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all),
        null: false

      add :inserted_at, :naive_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:user_message_deletions, [:user_id, :message_id])
    create index(:user_message_deletions, [:message_id])
  end
end
