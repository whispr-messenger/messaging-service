defmodule WhisprMessaging.Repo.Migrations.CreateDeviceSigningKeys do
  use Ecto.Migration

  def change do
    create table(:device_signing_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuid_generate_v4()")

      # The authenticated user this key belongs to.
      # One row per user — stores only the current active signing key.
      # Key rotation replaces the existing row (upsert on user_id).
      add :user_id, :binary_id, null: false

      # Base64-encoded 32-byte Ed25519 public key
      add :public_key_b64, :string, null: false

      timestamps()
    end

    create unique_index(:device_signing_keys, [:user_id],
             name: :device_signing_keys_user_id_index
           )
  end
end
