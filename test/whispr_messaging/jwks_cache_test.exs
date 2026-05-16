defmodule WhisprMessaging.JwksCacheTest do
  @moduledoc """
  Unit tests for the JwksCache GenServer.

  We avoid HTTP calls by using Finch mocking via :meck (the project already
  depends on {:mock, ~> 0.3.0}).

  The supervised JwksCache started by the application tree is stopped before
  each test and replaced by a freshly started one with `start_refresh: false`
  so each test starts from a deterministic empty state without racing with
  the periodic refresh.
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
    # In :test the application supervisor does NOT start JwksCache —
    # each test owns its own process with start_refresh: false.
    {:ok, pid} = JwksCache.start_link(start_refresh: false)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "get_signing_key/1 with kid" do
    test "returns :not_loaded when key has not been fetched yet" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:error, %Mint.TransportError{reason: :econnrefused}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("test-kid-1")
      end
    end

    test "returns {:ok, pem} after a successful JWKS fetch" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, pem} = JwksCache.get_signing_key("test-kid-1")
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

        assert {:ok, _pem} = JwksCache.get_signing_key("test-kid-1")
      end

      # Trigger a second refresh with a mock failure and verify key is retained
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 503, body: "service unavailable", headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        # Key should still be available from the previous successful fetch
        assert {:ok, _pem} = JwksCache.get_signing_key("test-kid-1")
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

    test "returns {:error, :not_loaded} on transport error during initial fetch" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:error, %Mint.TransportError{reason: :timeout}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("any-kid")
      end
    end

    test "get_signing_key(nil) returns the first cached key when keys are loaded" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, pem} = JwksCache.get_signing_key(nil)
        assert is_binary(pem)
        assert String.starts_with?(pem, "-----BEGIN")
      end
    end

    test "get_signing_key(nil) returns :not_loaded when no keys are cached yet" do
      assert {:error, :not_loaded} = JwksCache.get_signing_key(nil)
    end

    test "skips JWK entries that are not EC P-256 signing keys" do
      mixed_body =
        Jason.encode!(%{
          "keys" => [
            %{"kty" => "RSA", "kid" => "rsa-key", "use" => "sig"},
            @valid_jwk,
            %{"kty" => "EC", "crv" => "P-384", "kid" => "wrong-curve", "use" => "sig"}
          ]
        })

      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: mixed_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(200)

        assert {:ok, _pem} = JwksCache.get_signing_key("test-kid-1")
        assert {:error, :not_loaded} = JwksCache.get_signing_key("rsa-key")
        assert {:error, :not_loaded} = JwksCache.get_signing_key("wrong-curve")
      end
    end

    test "treats invalid JSON response as failed refresh and keeps state empty" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: "not valid json", headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("test-kid-1")
      end
    end

    test "JWKS response with no usable EC P-256 keys keeps state empty" do
      # The body parses fine but contains zero usable keys (only RSA + wrong curve)
      empty_body =
        Jason.encode!(%{
          "keys" => [
            %{"kty" => "RSA", "kid" => "rsa-1", "use" => "sig"},
            %{"kty" => "EC", "crv" => "P-384", "kid" => "wrong-curve", "use" => "sig"}
          ]
        })

      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: empty_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(150)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("rsa-1")
      end
    end

    test "treats JSON without 'keys' field as :invalid_document" do
      bad_body = Jason.encode!(%{"not_keys" => []})

      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: bad_body, headers: []}}
        end do
        send(JwksCache, :refresh)
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key("test-kid-1")
      end
    end
  end
end
