defmodule WhisprMessaging.Repo.Migrations.WidenAttachmentUrlColumns do
  use Ecto.Migration

  @moduledoc """
  Widens `storage_url` and `thumbnail_url` on `message_attachments` from
  `varchar(255)` to unbounded `text`.

  Media-service returns signed/CDN URLs that routinely exceed 255 characters,
  causing `POST /messages/:id/attachments` to fail with
  `22001 string_data_right_truncation` during insert.
  """

  def up do
    alter table(:message_attachments) do
      modify :storage_url, :text, null: false
      modify :thumbnail_url, :text, null: true
    end
  end

  def down do
    alter table(:message_attachments) do
      modify :storage_url, :string, null: false
      modify :thumbnail_url, :string, null: true
    end
  end
end
