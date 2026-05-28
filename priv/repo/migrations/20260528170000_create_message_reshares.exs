defmodule WhisprMessaging.Repo.Migrations.CreateMessageReshares do
  use Ecto.Migration

  @moduledoc """
  Re-share table for E2EE key_packets that bind an existing ciphertext
  envelope to a recipient device that did NOT exist (or was unknown to
  the sender) at the time the message was originally encrypted.

  When a user logs in on a brand new browser/app install, the resulting
  device has a fresh identity_key that no historical message can decrypt
  — every existing message's key_packets target devices that were
  registered before this one. To grant the new device read access
  without weakening the protocol, the user's OTHER existing devices
  re-encrypt the per-message key for the new device and POST a row to
  this table. The message read path then merges these into the envelope
  the new device sees, so its decrypt loop finds a packet it can open.

  Forwarding is initiated by the user's existing devices (which already
  hold the plaintext) — the server only stores opaque
  per-recipient-device packets and cannot decrypt anything.
  """

  def up do
    create table(:message_reshares, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("uuid_generate_v4()")

      add :message_id,
          references(:messages, type: :uuid, on_delete: :delete_all),
          null: false

      # Who the packet is encrypted FOR. user_id is denormalised so the
      # read path can filter without joining the auth schema.
      add :recipient_user_id, :uuid, null: false
      add :recipient_device_id, :uuid, null: false

      # The packet itself: nacl.box(message_key, nonce, recipient_pub, sender_secret)
      add :nonce, :text, null: false
      add :box, :text, null: false

      # Which device produced this reshare (audit / debugging).
      add :resharer_device_id, :uuid, null: false

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create unique_index(:message_reshares, [:message_id, :recipient_device_id],
             name: :message_reshares_message_recipient_device_uidx
           )

    # Hot read path: "give me all reshares for THIS device across the
    # messages I just fetched". Covering index on the FK lookup.
    create index(:message_reshares, [:recipient_device_id, :message_id])
  end

  def down do
    drop table(:message_reshares)
  end
end
