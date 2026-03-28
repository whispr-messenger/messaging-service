defmodule WhisprMessaging.Messages.SignatureVerifierTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Messages.{DeviceKeyStore, SignatureVerifier}

  # Generates a fresh Ed25519 key pair for testing
  defp generate_key_pair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {public_key, private_key}
  end

  defp sign(private_key, data) do
    :crypto.sign(:eddsa, :none, data, [private_key, :ed25519])
  end

  defp build_attrs(sender_id, public_key, private_key, overrides \\ %{}) do
    conversation_id = Ecto.UUID.generate()
    client_random = 42_000
    content = "encrypted_content_bytes"

    base_attrs = %{
      "content" => content,
      "conversation_id" => conversation_id,
      "client_random" => client_random,
      "sender_id" => sender_id
    }

    signed_data = SignatureVerifier.build_signed_data(base_attrs)
    signature = sign(private_key, signed_data)

    base_attrs
    |> Map.put("signature", Base.encode64(signature))
    |> Map.put("sender_public_key", Base.encode64(public_key))
    |> Map.merge(overrides)
  end

  describe "verify/1 — backward compatibility" do
    test "returns :ok when both signature fields are absent" do
      attrs = %{"content" => "test", "conversation_id" => Ecto.UUID.generate()}
      assert :ok = SignatureVerifier.verify(attrs)
    end

    test "returns :missing_signature_fields when only signature is provided" do
      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "sender_id" => Ecto.UUID.generate(),
        "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:error, :missing_signature_fields} = SignatureVerifier.verify(attrs)
    end

    test "returns :missing_signature_fields when only public key is provided" do
      {pub, _} = generate_key_pair()

      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "sender_id" => Ecto.UUID.generate(),
        "sender_public_key" => Base.encode64(pub)
      }

      assert {:error, :missing_signature_fields} = SignatureVerifier.verify(attrs)
    end
  end

  describe "verify/1 — TOFU key registration" do
    test "registers the key on first use and returns :ok" do
      sender_id = Ecto.UUID.generate()
      {pub, priv} = generate_key_pair()
      attrs = build_attrs(sender_id, pub, priv)

      assert :ok = SignatureVerifier.verify(attrs)

      # Key must now be stored
      assert {:ok, stored_key} = DeviceKeyStore.get_key(sender_id)
      assert stored_key == Base.encode64(pub)
    end

    test "accepts the same key on subsequent messages" do
      sender_id = Ecto.UUID.generate()
      {pub, priv} = generate_key_pair()

      # First message registers the key
      assert :ok = SignatureVerifier.verify(build_attrs(sender_id, pub, priv))

      # Second message with the same key is accepted
      assert :ok = SignatureVerifier.verify(build_attrs(sender_id, pub, priv))
    end
  end

  describe "verify/1 — impersonation protection" do
    test "rejects an attacker-supplied key that does not match the registered key" do
      sender_id = Ecto.UUID.generate()
      {legit_pub, legit_priv} = generate_key_pair()

      # Legitimate sender registers their key
      assert :ok = SignatureVerifier.verify(build_attrs(sender_id, legit_pub, legit_priv))

      # Attacker generates their own keypair and tries to sign as the same sender_id
      {attacker_pub, attacker_priv} = generate_key_pair()
      attacker_attrs = build_attrs(sender_id, attacker_pub, attacker_priv)

      assert {:error, :key_mismatch} = SignatureVerifier.verify(attacker_attrs)
    end

    test "returns :missing_sender_id when sender_id is absent" do
      {pub, priv} = generate_key_pair()

      attrs = build_attrs(Ecto.UUID.generate(), pub, priv)
      attrs_no_sender = Map.delete(attrs, "sender_id")

      assert {:error, :missing_sender_id} = SignatureVerifier.verify(attrs_no_sender)
    end
  end

  describe "verify/1 — cryptographic validation" do
    test "returns :ok for a valid Ed25519 signature" do
      sender_id = Ecto.UUID.generate()
      {pub, priv} = generate_key_pair()

      assert :ok = SignatureVerifier.verify(build_attrs(sender_id, pub, priv))
    end

    test "returns :invalid_signature for tampered content" do
      sender_id = Ecto.UUID.generate()
      {pub, priv} = generate_key_pair()

      attrs = build_attrs(sender_id, pub, priv, %{"content" => "tampered_content"})
      assert {:error, :invalid_signature} = SignatureVerifier.verify(attrs)
    end

    test "returns :invalid_signature when signature is from a different key" do
      sender_id = Ecto.UUID.generate()
      {pub, _} = generate_key_pair()
      {_, other_priv} = generate_key_pair()

      # Sign with other_priv but provide pub (matches registered key)
      # First register the legitimate key
      DeviceKeyStore.register_or_verify(sender_id, Base.encode64(pub))
      # Then sign data with the wrong private key
      attrs = build_attrs(sender_id, pub, other_priv)
      assert {:error, :invalid_signature} = SignatureVerifier.verify(attrs)
    end

    test "returns error for invalid base64 signature" do
      {pub, priv} = generate_key_pair()
      sender_id = Ecto.UUID.generate()
      attrs = build_attrs(sender_id, pub, priv, %{"signature" => "not-valid-base64!!!"})

      assert {:error, _} = SignatureVerifier.verify(attrs)
    end

    test "returns :invalid_key_length for a key with wrong byte size" do
      sender_id = Ecto.UUID.generate()
      {_pub, priv} = generate_key_pair()
      short_key = :crypto.strong_rand_bytes(16)

      data =
        SignatureVerifier.build_signed_data(%{
          "content" => "x",
          "conversation_id" => Ecto.UUID.generate(),
          "client_random" => 1
        })

      sig = sign(priv, data)

      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "sender_id" => sender_id,
        "signature" => Base.encode64(sig),
        "sender_public_key" => Base.encode64(short_key)
      }

      assert {:error, :invalid_key_length} = SignatureVerifier.verify(attrs)
    end
  end

  describe "DeviceKeyStore" do
    test "get_key/1 returns :not_found for unknown sender" do
      assert {:error, :not_found} = DeviceKeyStore.get_key(Ecto.UUID.generate())
    end

    test "register_or_verify/2 registers on first call" do
      user_id = Ecto.UUID.generate()
      {pub, _} = generate_key_pair()
      key_b64 = Base.encode64(pub)

      assert :ok = DeviceKeyStore.register_or_verify(user_id, key_b64)
      assert {:ok, ^key_b64} = DeviceKeyStore.get_key(user_id)
    end

    test "register_or_verify/2 returns :ok when key matches" do
      user_id = Ecto.UUID.generate()
      {pub, _} = generate_key_pair()
      key_b64 = Base.encode64(pub)

      DeviceKeyStore.register_or_verify(user_id, key_b64)
      assert :ok = DeviceKeyStore.register_or_verify(user_id, key_b64)
    end

    test "register_or_verify/2 returns :key_mismatch when key differs" do
      user_id = Ecto.UUID.generate()
      {pub1, _} = generate_key_pair()
      {pub2, _} = generate_key_pair()

      DeviceKeyStore.register_or_verify(user_id, Base.encode64(pub1))

      assert {:error, :key_mismatch} =
               DeviceKeyStore.register_or_verify(user_id, Base.encode64(pub2))
    end

    test "rotate_key/2 replaces the stored key" do
      user_id = Ecto.UUID.generate()
      {pub1, _} = generate_key_pair()
      {pub2, _} = generate_key_pair()

      DeviceKeyStore.register_or_verify(user_id, Base.encode64(pub1))
      assert :ok = DeviceKeyStore.rotate_key(user_id, Base.encode64(pub2))
      assert {:ok, stored} = DeviceKeyStore.get_key(user_id)
      assert stored == Base.encode64(pub2)
    end
  end
end
