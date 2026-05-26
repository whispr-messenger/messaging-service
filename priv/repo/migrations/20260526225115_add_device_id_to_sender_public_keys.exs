defmodule WhisprMessaging.Repo.Migrations.AddDeviceIdToSenderPublicKeys do
  use Ecto.Migration

  def change do
    # Les entrées existantes sont stales (bug mobile de régénération de clé) — on
    # vide la table avant de changer le schéma pour repartir d'un TOFU propre.
    execute("DELETE FROM sender_public_keys", "SELECT 1")

    alter table(:sender_public_keys) do
      add :device_id, :binary_id, null: true
    end

    # Supprime l'ancien index unique sur user_id seul
    drop_if_exists unique_index(:sender_public_keys, [:user_id])

    # TOFU par couple (user_id, device_id) — un device = une clé de confiance
    create unique_index(:sender_public_keys, [:user_id, :device_id])
  end
end
