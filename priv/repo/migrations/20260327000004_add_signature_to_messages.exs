defmodule WhisprMessaging.Repo.Migrations.AddSignatureToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Ed25519 signature over (content || conversation_id || client_random)
      # Base64-encoded, nullable for backwards compatibility
      add :signature, :text, null: true
      # Sender's Ed25519 public key in Base64 (32 bytes = 44 Base64 chars)
      add :sender_public_key, :text, null: true
    end

    create index(:messages, [:sender_id, :sender_public_key])
  end
end
