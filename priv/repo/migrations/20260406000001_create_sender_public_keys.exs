defmodule WhisprMessaging.Repo.Migrations.CreateSenderPublicKeys do
  use Ecto.Migration

  def change do
    create table(:sender_public_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id, null: false
      add :public_key, :text, null: false

      timestamps()
    end

    create unique_index(:sender_public_keys, [:user_id, :public_key])
    create index(:sender_public_keys, [:user_id])
  end
end
