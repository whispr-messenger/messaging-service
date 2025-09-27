defmodule WhisprMessaging.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    # Create messages table
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all), null: false
      add :sender_id, :binary_id, null: true  # null for system messages
      add :reply_to_id, references(:messages, type: :binary_id, on_delete: :nilify_all), null: true
      add :message_type, :string, null: false
      add :content, :binary, null: false  # Encrypted content as BYTEA
      add :metadata, :map, null: false, default: "{}"
      add :client_random, :integer, null: false
      add :sent_at, :utc_datetime, null: false
      add :edited_at, :utc_datetime, null: true
      add :is_deleted, :boolean, null: false, default: false
      add :delete_for_everyone, :boolean, null: false, default: false

      timestamps()
    end

    # Indexes for messages
    create index(:messages, [:conversation_id])
    create index(:messages, [:sender_id])
    create index(:messages, [:reply_to_id])
    create index(:messages, [:message_type])
    create index(:messages, [:sent_at])
    create index(:messages, [:is_deleted])
    create unique_index(:messages, [:sender_id, :client_random], name: :messages_sender_id_client_random_index)

    # Composite indexes for efficient queries
    create index(:messages, [:conversation_id, :sent_at])
    create index(:messages, [:conversation_id, :is_deleted, :sent_at])
    create index(:messages, [:sender_id, :sent_at])

    # Create delivery_statuses table
    create table(:delivery_statuses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :delivered_at, :utc_datetime, null: true
      add :read_at, :utc_datetime, null: true

      timestamps()
    end

    # Indexes for delivery_statuses
    create unique_index(:delivery_statuses, [:message_id, :user_id], name: :delivery_statuses_message_id_user_id_index)
    create index(:delivery_statuses, [:message_id])
    create index(:delivery_statuses, [:user_id])
    create index(:delivery_statuses, [:delivered_at])
    create index(:delivery_statuses, [:read_at])
    create index(:delivery_statuses, [:user_id, :delivered_at])
    create index(:delivery_statuses, [:user_id, :read_at])

    # Create message_reactions table
    create table(:message_reactions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, :binary_id, null: false
      add :reaction, :string, null: false

      timestamps()
    end

    # Indexes for message_reactions
    create unique_index(:message_reactions, [:message_id, :user_id, :reaction], name: :message_reactions_message_id_user_id_reaction_index)
    create index(:message_reactions, [:message_id])
    create index(:message_reactions, [:user_id])
    create index(:message_reactions, [:reaction])

    # Create message_attachments table
    create table(:message_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :file_type, :string, null: false
      add :file_size, :integer, null: false
      add :mime_type, :string, null: false
      add :storage_url, :string, null: false
      add :thumbnail_url, :string, null: true
      add :metadata, :map, null: false, default: "{}"
      add :encryption_key, :binary, null: true
      add :is_deleted, :boolean, null: false, default: false

      timestamps()
    end

    # Indexes for message_attachments
    create index(:message_attachments, [:message_id])
    create index(:message_attachments, [:file_type])
    create index(:message_attachments, [:is_deleted])
    create index(:message_attachments, [:message_id, :is_deleted])
  end
end