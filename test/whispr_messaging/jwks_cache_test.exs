defmodule WhisprMessaging.JwksCacheTest do
  @moduledoc """
  Unit tests for the JwksCache GenServer.

  We avoid HTTP calls by using Finch mocking via :meck (the project already
  depends on {:mock, ~> 0.3.0}).

  The JwksCache GenServer is started by the supervision tree, so we reset its
  internal state before each test via `:sys.replace_state/2`.
  """

  use ExUnit.Case, async: false

  import Mock

  alias WhisprMessaging.JwksCache

  # A minimal ES256 JWK with fake coordinates (only structure matters here)
  @valid_jwk %{
    "kty" => "EC",
    "crv" => "P-256",
    "use" => "sig",
    "alg" => "ES256",
    "kid" => "test-kid-1",
    "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
    "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
  }

  @valid_jwks_body Jason.encode!(%{"keys" => [@valid_jwk]})

  setup do
    # Reset the JwksCache state before each test so tests don't leak state
    :sys.replace_state(JwksCache, fn state -> %{state | keys: %{}} end)
    :ok
  end

  describe "get_signing_key/0" do
    test "returns :not_loaded when key has not been fetched yet" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:error, %Mint.TransportError{reason: :econnrefused}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key()
      end
    end

    test "returns {:ok, pem} after a successful JWKS fetch" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, pem} = JwksCache.get_signing_key()
        assert is_binary(pem)
        assert String.starts_with?(pem, "-----BEGIN")
      end
    end

    test "keeps previous key when refresh returns a non-200 response" do
      # First load a valid key
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, _pem} = JwksCache.get_signing_key()
      end

      # Trigger a second refresh with a mock failure and verify key is retained
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 503, body: "service unavailable", headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        # Key should still be available from the previous successful fetch
        assert {:ok, _pem} = JwksCache.get_signing_key()
      end
    end
  end

  describe "get_signing_key/1 with kid" do
    test "returns the key matching the given kid" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, pem} = JwksCache.get_signing_key("test-kid-1")
        assert is_binary(pem)
      end
    end

    test "returns :not_loaded for an unknown kid" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("unknown-kid")
      end
    end
  end
end
