defmodule WhisprMessaging.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reporter_id, :binary_id, null: false
      add :reported_user_id, :binary_id, null: false
      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :nilify_all)
      add :message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :category, :string, null: false
      add :description, :text
      add :evidence, :map, default: %{}
      add :status, :string, null: false, default: "pending"
      add :resolution, :map
      add :auto_escalated, :boolean, default: false

      timestamps()
    end

    create index(:reports, [:reporter_id])
    create index(:reports, [:reported_user_id])
    create index(:reports, [:status])
    create index(:reports, [:conversation_id])
    create index(:reports, [:reported_user_id, :inserted_at])
    create unique_index(:reports, [:reporter_id, :message_id], name: :reports_reporter_message_unique, where: "message_id IS NOT NULL AND status = 'pending'")
  end
end
