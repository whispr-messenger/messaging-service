defmodule WhisprMessaging.Repo.Migrations.AddForwardedFromIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :forwarded_from_id,
          references(:messages, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:messages, [:forwarded_from_id])
  end
end
