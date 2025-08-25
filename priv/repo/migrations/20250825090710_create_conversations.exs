defmodule WhisprMessaging.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    # Extension UUID
    execute "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""

    # Table des conversations
    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :type, :string, null: false, size: 20
      add :external_group_id, :uuid
      add :metadata, :map, null: false, default: %{}
      add :is_active, :boolean, null: false, default: true

      timestamps()
    end

    # Index pour conversations
    create index(:conversations, [:type])
    create index(:conversations, [:external_group_id])
    create index(:conversations, [:inserted_at])
    create index(:conversations, [:updated_at])
    create index(:conversations, [:is_active])

    # Contrainte pour le type
    create constraint(:conversations, :type_check, 
           check: "type IN ('direct', 'group')")

    # Table des membres de conversation
    create table(:conversation_members, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :uuid, null: false
      add :settings, :map, null: false, default: %{}
      add :joined_at, :utc_datetime, null: false, default: fragment("NOW()")
      add :last_read_at, :utc_datetime
      add :is_active, :boolean, null: false, default: true
    end

    # Index pour conversation_members
    create index(:conversation_members, [:conversation_id])
    create index(:conversation_members, [:user_id])
    create index(:conversation_members, [:last_read_at])
    create index(:conversation_members, [:is_active])
    create unique_index(:conversation_members, [:conversation_id, :user_id])

    # Table des messages
    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all), null: false
      add :sender_id, :uuid, null: false
      add :reply_to_id, references(:messages, type: :uuid, on_delete: :nilify_all)
      add :message_type, :string, null: false, size: 20
      add :content, :binary, null: false
      add :metadata, :map, null: false, default: %{}
      add :client_random, :integer, null: false
      add :sent_at, :utc_datetime, null: false, default: fragment("NOW()")
      add :edited_at, :utc_datetime
      add :is_deleted, :boolean, null: false, default: false
      add :delete_for_everyone, :boolean, null: false, default: false

      timestamps()
    end

    # Index pour messages
    create index(:messages, [:conversation_id])
    create index(:messages, [:sender_id])
    create index(:messages, [:reply_to_id])
    create index(:messages, [:sent_at])
    create index(:messages, [:conversation_id, :sent_at])
    create index(:messages, [:is_deleted])
    create unique_index(:messages, [:sender_id, :client_random])

    # Table des statuts de livraison
    create table(:delivery_statuses, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :uuid, null: false
      add :delivered_at, :utc_datetime
      add :read_at, :utc_datetime
    end

    # Index pour delivery_statuses
    create index(:delivery_statuses, [:message_id])
    create index(:delivery_statuses, [:user_id])
    create index(:delivery_statuses, [:delivered_at])
    create index(:delivery_statuses, [:read_at])
    create unique_index(:delivery_statuses, [:message_id, :user_id])

    # Table des messages épinglés
    create table(:pinned_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false
      add :pinned_by, :uuid, null: false
      add :pinned_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    # Index pour pinned_messages
    create index(:pinned_messages, [:conversation_id])
    create index(:pinned_messages, [:message_id])
    create index(:pinned_messages, [:pinned_at])
    create unique_index(:pinned_messages, [:conversation_id, :message_id])

    # Table des réactions aux messages
    create table(:message_reactions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false
      add :user_id, :uuid, null: false
      add :reaction, :string, null: false, size: 10
      add :created_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    # Index pour message_reactions
    create index(:message_reactions, [:message_id])
    create index(:message_reactions, [:user_id])
    create index(:message_reactions, [:reaction])
    create unique_index(:message_reactions, [:message_id, :user_id, :reaction])

    # Table des pièces jointes
    create table(:message_attachments, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false
      add :media_id, :uuid, null: false
      add :media_type, :string, null: false, size: 50
      add :metadata, :map, null: false, default: %{}
      add :created_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    # Index pour message_attachments
    create index(:message_attachments, [:message_id])
    create index(:message_attachments, [:media_id])
    create index(:message_attachments, [:media_type])

    # Table des paramètres de conversation
    create table(:conversation_settings, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all), null: false
      add :settings, :map, null: false, default: %{}
      add :updated_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    # Index pour conversation_settings
    create unique_index(:conversation_settings, [:conversation_id])
    create index(:conversation_settings, [:updated_at])

    # Table des messages programmés
    create table(:scheduled_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all), null: false
      add :sender_id, :uuid, null: false
      add :message_type, :string, null: false, size: 20
      add :content, :binary, null: false
      add :metadata, :map, null: false, default: %{}
      add :scheduled_for, :utc_datetime, null: false
      add :created_at, :utc_datetime, null: false, default: fragment("NOW()")
      add :is_sent, :boolean, null: false, default: false
      add :is_cancelled, :boolean, null: false, default: false
    end

    # Index pour scheduled_messages
    create index(:scheduled_messages, [:conversation_id])
    create index(:scheduled_messages, [:sender_id])
    create index(:scheduled_messages, [:scheduled_for])
    create index(:scheduled_messages, [:is_sent, :is_cancelled, :scheduled_for])
  end
end
