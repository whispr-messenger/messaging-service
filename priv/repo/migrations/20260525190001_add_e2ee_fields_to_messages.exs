defmodule WhisprMessaging.Repo.Migrations.AddE2eeFieldsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Rendre content nullable pour autoriser les messages E2EE (ciphertext seulement)
      modify :content, :binary, null: true, from: {:binary, null: false}

      # Ciphertext Olm — binaire nullable (nil pour les messages plaintext)
      add :ciphertext, :binary, null: true

      # Format du contenu : "plaintext" par defaut, "olm_v1" pour E2EE
      add :content_format, :string, null: false, default: "plaintext"
    end

    # Index partiel pour acces rapide aux messages E2EE dans une conversation
    create index(:messages, [:conversation_id, :content_format],
             where: "content_format != 'plaintext'",
             name: :messages_conversation_id_e2ee_format_index
           )
  end
end
