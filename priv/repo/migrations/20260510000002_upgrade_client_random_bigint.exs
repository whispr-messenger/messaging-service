defmodule WhisprMessaging.Repo.Migrations.UpgradeClientRandomBigint do
  use Ecto.Migration

  def up do
    # client_random est un Uint32 cote client (range 0..4294967295)
    # int4 postgres ne supporte que jusqu'a 2147483647 — ~36% des valeurs crashent en 500
    alter table(:messages) do
      modify :client_random, :bigint
    end

    alter table(:scheduled_messages) do
      modify :client_random, :bigint
    end
  end

  def down do
    alter table(:messages) do
      modify :client_random, :integer
    end

    alter table(:scheduled_messages) do
      modify :client_random, :integer
    end
  end
end
