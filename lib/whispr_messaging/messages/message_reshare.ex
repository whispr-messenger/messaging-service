defmodule WhisprMessaging.Messages.MessageReshare do
  @moduledoc """
  Per-recipient-device key_packet re-encrypted by an existing device of the
  user so that a freshly-registered device can decrypt historical messages
  whose original envelope did not include it.

  See the matching migration for the full rationale.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reshares" do
    field :recipient_user_id, :binary_id
    field :recipient_device_id, :binary_id
    field :nonce, :string
    field :box, :string
    field :resharer_device_id, :binary_id
    # Curve25519 public identity key of the resharer (base64). The reshare box
    # is sealed with the resharer's secret, NOT the original sender's, so the
    # recipient must open it with THIS key — not envelope.sender.identity_key.
    # Required for cross-sender history (a member re-sharing another user's
    # messages to a newly-joined member).
    field :resharer_identity_key, :string

    belongs_to :message, Message, foreign_key: :message_id

    timestamps(updated_at: false, type: :utc_datetime)
  end

  @required ~w(message_id recipient_user_id recipient_device_id nonce box resharer_device_id resharer_identity_key)a

  def changeset(reshare, attrs) do
    reshare
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:message_id, :recipient_device_id],
      name: :message_reshares_message_recipient_device_uidx
    )
    |> foreign_key_constraint(:message_id, name: :message_reshares_message_id_fkey)
  end
end
