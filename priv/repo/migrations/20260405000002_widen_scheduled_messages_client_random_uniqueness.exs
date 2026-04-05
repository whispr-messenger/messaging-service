defmodule WhisprMessaging.Repo.Migrations.WidenScheduledMessagesClientRandomUniqueness do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:scheduled_messages, [:sender_id, :client_random],
                     name: :scheduled_messages_sender_client_random_pending_unique
                   )

    create unique_index(:scheduled_messages, [:sender_id, :client_random],
             name: :scheduled_messages_sender_client_random_unique
           )
  end
end
