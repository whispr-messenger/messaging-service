defmodule WhisprMessaging.Messages.SenderPublicKey do
  @moduledoc """
  Stores trusted Ed25519 public keys for message senders (TOFU model).

  On the first signed message from a sender, the provided public key is
  registered. Subsequent messages from the same sender must use a key
  that has been previously registered, preventing impersonation via
  client-supplied keys.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sender_public_keys" do
    field :user_id, :binary_id
    field :public_key, :string

    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :public_key])
    |> validate_required([:user_id, :public_key])
    |> unique_constraint([:user_id, :public_key])
  end
end
