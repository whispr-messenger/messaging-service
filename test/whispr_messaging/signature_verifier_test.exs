defmodule WhisprMessaging.Messages.SignatureVerifierTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Messages.SignatureVerifier
  alias WhisprMessaging.Messages.SenderPublicKey
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
  end
end
