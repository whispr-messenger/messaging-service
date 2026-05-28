defmodule WhisprMessaging.Repo.Migrations.AddResharerIdentityKeyToReshares do
  @moduledoc """
  Adds the resharer's Curve25519 public identity key to each reshare row.

  A reshare packet's box is sealed with the RESHARER's secret key, so the
  recipient must open it with the resharer's public key — not the original
  envelope sender's. Without this column cross-sender reshare (an existing
  group member re-sharing another user's historical messages to a
  newly-joined member) could never be decrypted by the recipient.

  Nullable so the migration succeeds on any pre-existing rows; new inserts
  require it at the schema/changeset layer.
  """
  use Ecto.Migration

  def change do
    alter table(:message_reshares) do
      add :resharer_identity_key, :text
    end
  end
end
