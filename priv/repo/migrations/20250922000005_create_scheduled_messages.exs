defmodule WhisprMessaging.Repo.Migrations.CreateScheduledMessages do
  use Ecto.Migration

  def change do
    create table(:scheduled_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :sender_id, :binary_id, null: false
      # Encrypted content consistent with sent messages
      add :content, :binary, null: false
      add :message_type, :string, null: false, default: "text"
      add :metadata, :map, null: false, default: "{}"
      add :client_random, :integer, null: false
      # When the message should be sent
      add :scheduled_at, :utc_datetime, null: false
      # Status: pending | sent | cancelled
      add :status, :string, null: false, default: "pending"

      timestamps()
    end

    create index(:scheduled_messages, [:conversation_id])
    create index(:scheduled_messages, [:sender_id])
    create index(:scheduled_messages, [:scheduled_at])
    create index(:scheduled_messages, [:status])

    # Index for the worker to efficiently find pending messages due for dispatch
    create index(:scheduled_messages, [:status, :scheduled_at],
             name: :scheduled_messages_status_scheduled_at_index
           )

    # Index for listing a user's pending scheduled messages
    create index(:scheduled_messages, [:sender_id, :status, :scheduled_at],
             name: :scheduled_messages_sender_status_scheduled_at_index
           )
  end
end
