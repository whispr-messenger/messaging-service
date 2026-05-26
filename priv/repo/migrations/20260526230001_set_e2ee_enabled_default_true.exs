defmodule WhisprMessaging.Repo.Migrations.SetE2eeEnabledDefaultTrue do
  use Ecto.Migration

  def change do
    # Nouvelles convs activent E2EE par defaut — pas de backfill, les convs
    # existantes (e2ee_enabled=false) restent en plaintext opt-out.
    alter table(:conversations) do
      modify :e2ee_enabled, :boolean, null: false, default: true, from: {:boolean, null: false, default: false}
    end
  end
end
