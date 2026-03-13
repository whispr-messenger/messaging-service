defmodule WhisprMessaging.Repo.Migrations.AddUserDeletedConversationsAndPinnedConversations do
  use Ecto.Migration

  def change do
    # Per-user conversation soft delete (delete conversation for me)
    create table(:user_deleted_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, :binary_id, null: false
      add :deleted_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:user_deleted_conversations, [:conversation_id, :user_id],
      name: :user_deleted_conversations_conv_user_index
    )

    create index(:user_deleted_conversations, [:user_id])
    create index(:user_deleted_conversations, [:conversation_id])

    # Per-user pinned conversations
    create table(:pinned_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, :binary_id, null: false
      add :pinned_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:pinned_conversations, [:conversation_id, :user_id],
      name: :pinned_conversations_conv_user_index
    )

    create index(:pinned_conversations, [:user_id])
    create index(:pinned_conversations, [:conversation_id])
  end
end
