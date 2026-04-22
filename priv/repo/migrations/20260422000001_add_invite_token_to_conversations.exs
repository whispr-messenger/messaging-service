defmodule WhisprMessaging.Repo.Migrations.AddInviteTokenToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :invite_token, :binary_id
      add :invite_expires_at, :utc_datetime
    end

    create unique_index(:conversations, [:invite_token], where: "invite_token IS NOT NULL")
  end
end
