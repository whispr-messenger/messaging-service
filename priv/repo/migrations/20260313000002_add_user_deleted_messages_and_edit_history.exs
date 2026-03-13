defmodule WhisprMessaging.Repo.Migrations.AddUserDeletedMessagesAndEditHistory do
  use Ecto.Migration

  def change do
    # Per-user message deletion tracking (delete for me)
    create table(:user_deleted_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :deleted_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:user_deleted_messages, [:message_id, :user_id],
      name: :user_deleted_messages_message_id_user_id_index
    )
    create index(:user_deleted_messages, [:user_id])
    create index(:user_deleted_messages, [:message_id])

    # Edit history tracking
    create table(:message_edit_history, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :old_content, :binary, null: false
      add :edited_by, :binary_id, null: false
      add :edited_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:message_edit_history, [:message_id])
    create index(:message_edit_history, [:message_id, :edited_at])
  end
end
