defmodule WhisprMessaging.Messages.SignatureVerifierTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Messages.SenderPublicKey
  alias WhisprMessaging.Messages.SignatureVerifier
  alias WhisprMessaging.Repo

  # Generates a fresh Ed25519 key pair for testing
  defp generate_key_pair do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {public_key, private_key}
  end

  defp sign(private_key, data) do
    :crypto.sign(:eddsa, :none, data, [private_key, :ed25519])
  end

  defp build_attrs(public_key, private_key, overrides \\ %{}) do
    conversation_id = Ecto.UUID.generate()
    client_random = 42_000
    content = "encrypted_content_bytes"

    base_attrs = %{
      "content" => content,
      "conversation_id" => conversation_id,
      "client_random" => client_random,
      "sender_id" => Ecto.UUID.generate()
    }

    signed_data = SignatureVerifier.build_signed_data(base_attrs)
    signature = sign(private_key, signed_data)

    base_attrs
    |> Map.put("signature", Base.encode64(signature))
    |> Map.put("sender_public_key", Base.encode64(public_key))
    |> Map.merge(overrides)
  end

  describe "verify/1" do
    test "returns :ok when both fields are absent (backward compat)" do
      attrs = %{"content" => "test", "conversation_id" => Ecto.UUID.generate()}
      assert :ok = SignatureVerifier.verify(attrs)
    end

    test "returns :ok for a valid Ed25519 signature (TOFU registration)" do
      {public_key, private_key} = generate_key_pair()
      attrs = build_attrs(public_key, private_key)
      assert :ok = SignatureVerifier.verify(attrs)

      # Key should now be registered
      sender_id = attrs["sender_id"]
      assert Repo.exists?(from k in SenderPublicKey, where: k.user_id == ^sender_id)
    end

    test "returns :ok when using a previously registered key" do
      {public_key, private_key} = generate_key_pair()
      sender_id = Ecto.UUID.generate()
      attrs = build_attrs(public_key, private_key, %{"sender_id" => sender_id})

      # First message registers the key
      assert :ok = SignatureVerifier.verify(attrs)

      # Second message with same key should also pass
      attrs2 = build_attrs(public_key, private_key, %{"sender_id" => sender_id})
      assert :ok = SignatureVerifier.verify(attrs2)
    end

    test "rejects an untrusted key when a different key is already registered" do
      {pub1, priv1} = generate_key_pair()
      {pub2, priv2} = generate_key_pair()
      sender_id = Ecto.UUID.generate()

      # Register first key
      attrs1 = build_attrs(pub1, priv1, %{"sender_id" => sender_id})
      assert :ok = SignatureVerifier.verify(attrs1)

      # Try with a different key — should be rejected
      attrs2 = build_attrs(pub2, priv2, %{"sender_id" => sender_id})
      assert {:error, :untrusted_public_key} = SignatureVerifier.verify(attrs2)
    end

    test "returns {:error, :invalid_signature} for a tampered content" do
      {public_key, private_key} = generate_key_pair()
      attrs = build_attrs(public_key, private_key, %{"content" => "tampered_content"})
      assert {:error, :invalid_signature} = SignatureVerifier.verify(attrs)
    end

    test "returns {:error, :invalid_signature} for a wrong key" do
      {_other_pub, other_priv} = generate_key_pair()
      {real_pub, _real_priv} = generate_key_pair()
      # Sign with other_priv but provide real_pub
      attrs = build_attrs(real_pub, other_priv)
      assert {:error, :invalid_signature} = SignatureVerifier.verify(attrs)
    end

    test "returns error when only signature is provided" do
      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
      }

      assert {:error, :missing_signature_fields} = SignatureVerifier.verify(attrs)
    end

    test "returns error when only public key is provided" do
      {pub, _} = generate_key_pair()

      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "sender_public_key" => Base.encode64(pub)
      }

      assert {:error, :missing_signature_fields} = SignatureVerifier.verify(attrs)
    end

    test "returns error for invalid base64 signature" do
      {pub, _} = generate_key_pair()

      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "signature" => "not-valid-base64!!!",
        "sender_public_key" => Base.encode64(pub)
      }

      assert {:error, _} = SignatureVerifier.verify(attrs)
    end

    test "returns error for wrong key length" do
      {_pub, priv} = generate_key_pair()
      # Use a 16-byte key instead of 32
      short_key = :crypto.strong_rand_bytes(16)
      conversation_id = Ecto.UUID.generate()

      data =
        SignatureVerifier.build_signed_data(%{
          "content" => "x",
          "conversation_id" => conversation_id,
          "client_random" => 1
        })

      sig = sign(priv, data)

      attrs = %{
        "content" => "x",
        "conversation_id" => conversation_id,
        "client_random" => 1,
        "signature" => Base.encode64(sig),
        "sender_public_key" => Base.encode64(short_key)
      }

      assert {:error, :invalid_key_length} = SignatureVerifier.verify(attrs)
    end

    test "returns error for wrong signature length" do
      {pub, _priv} = generate_key_pair()
      # Build a 32-byte signature that decodes to half of the expected 64
      short_sig = :crypto.strong_rand_bytes(32)

      attrs = %{
        "content" => "x",
        "conversation_id" => Ecto.UUID.generate(),
        "client_random" => 1,
        "signature" => Base.encode64(short_sig),
        "sender_public_key" => Base.encode64(pub)
      }

      assert {:error, :invalid_signature_length} = SignatureVerifier.verify(attrs)
    end
  end

  describe "verify_trusted_key/2" do
    test "returns :ok immediately when sender_id is nil (backward compat)" do
      assert :ok = SignatureVerifier.verify_trusted_key(nil, "some_key_b64")
    end

    test "registers a key via TOFU on first call" do
      sender_id = Ecto.UUID.generate()
      key_b64 = Base.encode64(:crypto.strong_rand_bytes(32))

      assert :ok = SignatureVerifier.verify_trusted_key(sender_id, key_b64)

      stored = Repo.get_by(SenderPublicKey, user_id: sender_id)
      assert stored.public_key == key_b64
    end

    test "returns :ok when the provided key matches the stored one" do
      sender_id = Ecto.UUID.generate()
      key_b64 = Base.encode64(:crypto.strong_rand_bytes(32))
      :ok = SignatureVerifier.verify_trusted_key(sender_id, key_b64)
      assert :ok = SignatureVerifier.verify_trusted_key(sender_id, key_b64)
    end

    test "returns :untrusted_public_key when the key has changed" do
      sender_id = Ecto.UUID.generate()
      key1 = Base.encode64(:crypto.strong_rand_bytes(32))
      key2 = Base.encode64(:crypto.strong_rand_bytes(32))
      :ok = SignatureVerifier.verify_trusted_key(sender_id, key1)

      assert {:error, :untrusted_public_key} =
               SignatureVerifier.verify_trusted_key(sender_id, key2)
    end
  end

  describe "build_signed_data/1" do
    test "accepts atom keys as a fallback" do
      out =
        SignatureVerifier.build_signed_data(%{
          content: "abc",
          conversation_id: Ecto.UUID.generate(),
          client_random: 7
        })

      assert is_binary(out)
    end

    test "uses '' / '' / 0 as defaults when keys are missing" do
      out = SignatureVerifier.build_signed_data(%{})
      # 0 attrs → just <<0::big-32>> = 4 bytes (content "" + conv_id "" + 32-bit 0)
      assert byte_size(out) == 4
    end

    test "passes through a non-UUID conversation_id as raw bytes" do
      out =
        SignatureVerifier.build_signed_data(%{
          "content" => "x",
          "conversation_id" => "not-a-uuid",
          "client_random" => 1
        })

      assert is_binary(out)
      # "x" (1) + "not-a-uuid" (10) + 4 bytes
      assert byte_size(out) == 15
    end
  end
end
