defmodule WhisprMessaging.Repo.Migrations.AddUniqueClientRandomToScheduledMessages do
  use Ecto.Migration

  def change do
    create unique_index(:scheduled_messages, [:sender_id, :client_random],
             where: "status = 'pending'",
             name: :scheduled_messages_sender_client_random_pending_unique
           )
  end
end
