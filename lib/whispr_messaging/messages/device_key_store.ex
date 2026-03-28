defmodule WhisprMessaging.Messages.DeviceKeyStore do
  @moduledoc """
  Server-side trust store for device Ed25519 signing keys.

  ## Trust model — Trust On First Use (TOFU)

  The first time a user sends a signed message the supplied `sender_public_key`
  is stored and becomes the authoritative key for that user.  Every subsequent
  signed message from the same `sender_id` must use the same key.

  If the keys differ the message is rejected with `{:error, :key_mismatch}`,
  protecting against an attacker who generates their own keypair and supplies
  it inline with the request.

  ## Key rotation

  Key rotation is intentionally out of scope for this implementation.  A
  future endpoint (e.g. `PUT /me/signing-key`) with proper re-authentication
  can replace the stored key by calling `rotate_key/2`.

  ## Why not rely on the auth-service JWKS?

  The auth-service JWKS endpoint provides **JWT signature keys** (ECDSA
  P-256) used for session authentication, not E2E message signing keys.
  Those are distinct keypairs controlled by the client device.
  """

  import Ecto.Query, warn: false

  alias WhisprMessaging.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  use Ecto.Schema
  import Ecto.Changeset

  schema "device_signing_keys" do
    field :user_id, :binary_id
    field :public_key_b64, :string

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:user_id, :public_key_b64])
    |> validate_required([:user_id, :public_key_b64])
    |> unique_constraint(:user_id, name: :device_signing_keys_user_id_index)
  end

  @doc """
  Retrieves the registered public key for `user_id`, or `nil` if not yet
  registered.
  """
  @spec get_key(binary()) :: {:ok, String.t()} | {:error, :not_found}
  def get_key(user_id) do
    case Repo.one(from k in __MODULE__, where: k.user_id == ^user_id) do
      nil -> {:error, :not_found}
      record -> {:ok, record.public_key_b64}
    end
  end

  @doc """
  Registers `public_key_b64` for `user_id` (first use) or verifies it
  matches the already-stored key (subsequent use).

  Returns `:ok` on success, `{:error, :key_mismatch}` if the supplied key
  does not match the registered key.
  """
  @spec register_or_verify(binary(), String.t()) :: :ok | {:error, :key_mismatch}
  def register_or_verify(user_id, public_key_b64) do
    case get_key(user_id) do
      {:error, :not_found} ->
        # First use — register the key
        %__MODULE__{}
        |> changeset(%{user_id: user_id, public_key_b64: public_key_b64})
        |> Repo.insert(
          on_conflict: [set: [public_key_b64: public_key_b64, updated_at: DateTime.utc_now()]],
          conflict_target: :user_id
        )
        |> case do
          {:ok, _} -> :ok
          {:error, _changeset} -> :ok
        end

      {:ok, stored_key} ->
        if stored_key == public_key_b64 do
          :ok
        else
          {:error, :key_mismatch}
        end
    end
  end

  @doc """
  Replaces the registered key for `user_id` with a new one.

  This is the key rotation path and should only be called from a dedicated
  endpoint that requires strong re-authentication.
  """
  @spec rotate_key(binary(), String.t()) :: :ok | {:error, term()}
  def rotate_key(user_id, new_public_key_b64) do
    result =
      Repo.insert(
        %__MODULE__{user_id: user_id, public_key_b64: new_public_key_b64},
        on_conflict: [set: [public_key_b64: new_public_key_b64, updated_at: DateTime.utc_now()]],
        conflict_target: :user_id
      )

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
