defmodule WhisprMessaging.Messages.SignatureVerifier do
  @moduledoc """
  Server-side cryptographic signature verification for E2E messages.

  The scheme is Ed25519 (EdDSA). The client signs a canonical byte string
  derived from the ciphertext without ever exposing plaintext to the server:

    signed_data = content <> conversation_id_bytes <> <<client_random::big-32>>

  ## Trust On First Use (TOFU)

  The server maintains a store of trusted public keys per sender. On the
  first signed message from a user, the provided key is registered. On
  subsequent messages, the server verifies against the stored key and
  rejects any key that has not been previously registered.

  This prevents an attacker from substituting both the signature and key
  to forge a valid-looking message — the server will only accept keys it
  has seen before for a given sender.
  """

  import Ecto.Query, warn: false

  alias WhisprMessaging.Messages.SenderPublicKey
  alias WhisprMessaging.Repo

  require Logger

  @doc """
  Verifies the Ed25519 signature on a message payload.

  Returns `:ok` if the signature is valid or if signature verification is
  not required (both fields absent — backward-compatible mode).

  Returns `{:error, reason}` on verification failure.
  """
  @spec verify(map()) :: :ok | {:error, atom()}
  def verify(attrs) do
    signature_b64 = attrs["signature"] || attrs[:signature]
    public_key_b64 = attrs["sender_public_key"] || attrs[:sender_public_key]

    cond do
      # Both absent — no verification required (backward-compat)
      is_nil(signature_b64) and is_nil(public_key_b64) ->
        :ok

      # One present, one absent — malformed request
      is_nil(signature_b64) or is_nil(public_key_b64) ->
        {:error, :missing_signature_fields}

      true ->
        sender_id = attrs["sender_id"] || attrs[:sender_id]
        do_verify(attrs, signature_b64, public_key_b64, sender_id)
    end
  end

  defp do_verify(attrs, signature_b64, public_key_b64, sender_id) do
    with {:ok, signature} <- decode_base64(signature_b64, :signature),
         {:ok, public_key} <- decode_base64(public_key_b64, :public_key),
         :ok <- validate_key_length(public_key),
         :ok <- validate_signature_length(signature),
         :ok <- verify_trusted_key(sender_id, public_key_b64),
         signed_data <- build_signed_data(attrs) do
      if :crypto.verify(:eddsa, :none, signed_data, signature, [public_key, :ed25519]) do
        :ok
      else
        Logger.warning("Message signature verification failed for sender=#{inspect(sender_id)}")
        {:error, :invalid_signature}
      end
    end
  rescue
    e ->
      Logger.error("Signature verification error: #{inspect(e)}")
      {:error, :verification_error}
  end

  @doc false
  def verify_trusted_key(nil, _public_key_b64), do: :ok

  def verify_trusted_key(sender_id, public_key_b64) do
    known_keys =
      from(k in SenderPublicKey, where: k.user_id == ^sender_id, select: k.public_key)
      |> Repo.all()

    cond do
      # No keys registered yet — TOFU: register this key
      known_keys == [] ->
        register_key(sender_id, public_key_b64)

      # Provided key is already trusted
      public_key_b64 in known_keys ->
        :ok

      # Provided key is unknown — reject
      true ->
        Logger.warning(
          "Untrusted public key for sender=#{inspect(sender_id)}, " <>
            "known_keys=#{length(known_keys)}"
        )

        {:error, :untrusted_public_key}
    end
  end

  defp register_key(sender_id, public_key_b64) do
    case %SenderPublicKey{}
         |> SenderPublicKey.changeset(%{user_id: sender_id, public_key: public_key_b64})
         |> Repo.insert(on_conflict: :nothing) do
      {:ok, _} ->
        Logger.info("Registered new public key for sender=#{inspect(sender_id)} (TOFU)")
        :ok

      {:error, _} ->
        # Race condition: key was registered by another request
        :ok
    end
  end

  @doc """
  Builds the canonical signed data from message attributes.

  signed_data = content <> conversation_id_bytes <> <<client_random::big-32>>
  """
  def build_signed_data(attrs) do
    content = fetch_attr(attrs, "content", :content, "")
    conversation_id = fetch_attr(attrs, "conversation_id", :conversation_id, "")
    client_random = fetch_attr(attrs, "client_random", :client_random, 0)

    content_bytes(content) <> uuid_to_bytes(conversation_id) <> <<client_random::big-32>>
  end

  defp fetch_attr(attrs, key, atom_key, default) do
    attrs[key] || attrs[atom_key] || default
  end

  defp uuid_to_bytes(conversation_id) do
    case Ecto.UUID.dump(conversation_id) do
      {:ok, bytes} -> bytes
      _ -> conversation_id
    end
  end

  defp content_bytes(content) when is_binary(content), do: content
  defp content_bytes(content), do: to_string(content)

  defp decode_base64(b64, field) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :"invalid_#{field}_encoding"}
    end
  end

  defp validate_key_length(key) when byte_size(key) == 32, do: :ok
  defp validate_key_length(_), do: {:error, :invalid_key_length}

  defp validate_signature_length(sig) when byte_size(sig) == 64, do: :ok
  defp validate_signature_length(_), do: {:error, :invalid_signature_length}
end
