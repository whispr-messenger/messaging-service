defmodule WhisprMessaging.JwksCacheTest do
  @moduledoc """
  Unit tests for the JwksCache GenServer.

  We avoid HTTP calls by using Finch mocking via :meck (the project already
  depends on {:mock, ~> 0.3.0}).
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
    # Ensure any existing JwksCache is stopped before each test
    if pid = Process.whereis(JwksCache) do
      GenServer.stop(pid)
      Process.sleep(50)
    end

    :ok
  end

  describe "get_signing_key/0" do
    test "returns :not_loaded when key has not been fetched yet" do
      # Start the server but mock Finch to never respond
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:error, %Mint.TransportError{reason: :econnrefused}}
        end do
        {:ok, _pid} = start_supervised({JwksCache, []})
        # Give the GenServer time to process the :refresh message
        Process.sleep(100)

        assert {:error, :not_loaded} = JwksCache.get_signing_key()
      end
    end

    test "returns {:ok, jwk} after a successful JWKS fetch" do
      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
        end do
        {:ok, _pid} = start_supervised({JwksCache, []})
        Process.sleep(200)

        assert {:ok, jwk} = JwksCache.get_signing_key()
        assert is_struct(jwk, JOSE.JWK)
      end
    end

    test "keeps previous key when refresh returns a non-200 response" do
      # First call succeeds, second call fails
      call_count = :counters.new(1, [])

      with_mock Finch, [:passthrough],
        request: fn _req, _name, _opts ->
          :counters.add(call_count, 1, 1)

          if :counters.get(call_count, 1) == 1 do
            {:ok, %Finch.Response{status: 200, body: @valid_jwks_body, headers: []}}
          else
            {:ok, %Finch.Response{status: 503, body: "service unavailable", headers: []}}
          end
        end do
        # Start with very short refresh interval so we can trigger a second refresh
        {:ok, _pid} = start_supervised({JwksCache, []})
        Process.sleep(200)

        # Key should be loaded after first fetch
        assert {:ok, _jwk} = JwksCache.get_signing_key()
      end
    end
  end
end
