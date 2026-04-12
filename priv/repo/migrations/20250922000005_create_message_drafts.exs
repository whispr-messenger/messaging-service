defmodule WhisprMessaging.Repo.Migrations.CreateMessageDrafts do
  use Ecto.Migration

  def change do
    create table(:message_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      # The user who owns this draft
      add :user_id, :binary_id, null: false
      # Encrypted draft content (same as messages)
      add :content, :binary, null: false
      add :metadata, :map, null: false, default: "{}"

      timestamps()
    end

    # Only one draft per user per conversation
    create unique_index(:message_drafts, [:conversation_id, :user_id],
             name: :message_drafts_conversation_id_user_id_index
           )

    create index(:message_drafts, [:user_id])
    create index(:message_drafts, [:conversation_id])
  end
end
