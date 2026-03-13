defmodule WhisprMessaging.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :pinned_by, :binary_id, null: false
      add :pinned_at, :utc_datetime, null: false

      timestamps()
    end

    # Indexes for pinned_messages
    create unique_index(:pinned_messages, [:message_id], name: :pinned_messages_message_id_index)
    create index(:pinned_messages, [:conversation_id])
    create index(:pinned_messages, [:pinned_by])
    create index(:pinned_messages, [:pinned_at])
    create index(:pinned_messages, [:conversation_id, :pinned_at])
  end
end
