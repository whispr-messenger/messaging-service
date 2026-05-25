defmodule WhisprMessaging.Repo.Migrations.AddE2eeEnabledToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Flag E2EE par conversation — false par defaut, settable via PATCH explicite
      add :e2ee_enabled, :boolean, null: false, default: false
    end

    # Index pour filtrer efficacement les convs E2EE dans la recherche
    create index(:conversations, [:e2ee_enabled],
             where: "e2ee_enabled = true",
             name: :conversations_e2ee_enabled_index
           )
  end
end
