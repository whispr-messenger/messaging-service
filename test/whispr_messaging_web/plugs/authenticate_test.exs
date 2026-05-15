defmodule WhisprMessagingWeb.Plugs.AuthenticateTest do
  @moduledoc """
  Unit tests for the JWT/JWKS-driven authentication plug.

  These tests exercise the `WhisprMessagingWeb.Plugs.Authenticate.call/2`
  function directly with hand-crafted `%Plug.Conn{}` structs so we can
  validate every branch without going through the router.

  The `test_token_<user_id>` shortcut is also covered.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Mock

  alias WhisprMessaging.JwksCache
  alias WhisprMessagingWeb.Plugs.Authenticate

  defp run(conn) do
    Authenticate.call(conn, Authenticate.init([]))
  end

  describe "x-user-id gateway header" do
    test "assigns user_id when present and non-empty" do
      conn =
        conn(:get, "/anything")
        |> put_req_header("x-user-id", "user-abc")
        |> run()

      assert conn.assigns.user_id == "user-abc"
      refute conn.halted
    end

    test "ignores empty x-user-id and falls through to next strategy" do
      conn =
        conn(:get, "/anything")
        |> put_req_header("x-user-id", "")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end
  end

  describe "Authorization: Bearer test_token_*" do
    test "accepts test_token_<user_id> in :test env and assigns the user_id" do
      user_id = "test-user-xyz"

      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Bearer test_token_#{user_id}")
        |> run()

      assert conn.assigns.user_id == user_id
    end

    test "rejects empty test_token_ payload" do
      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Bearer test_token_")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end
  end

  describe "missing or malformed credentials" do
    test "does not assign user_id when no headers are provided" do
      conn = run(conn(:get, "/anything"))
      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "rejects an Authorization header that is not Bearer" do
      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "rejects a Bearer token that is not Base64-decodable" do
      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Bearer ###not base64###")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "rejects a Bearer token with no kid header" do
      # Header without a kid claim, plus arbitrary payload + signature parts
      header = Base.url_encode64(Jason.encode!(%{"alg" => "ES256"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"sub" => "x"}), padding: false)
      token = "#{header}.#{payload}.sig"

      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Bearer #{token}")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end
  end

  describe "Bearer token with a kid that targets JwksCache" do
    setup do
      # The application supervisor doesn't start JwksCache in :test —
      # we own a dedicated process for the duration of this describe block.
      {:ok, pid} = JwksCache.start_link(start_refresh: false)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      end)

      header =
        Base.url_encode64(Jason.encode!(%{"alg" => "ES256", "kid" => "k1"}), padding: false)

      payload = Base.url_encode64(Jason.encode!(%{"sub" => "user-xyz"}), padding: false)
      token = "#{header}.#{payload}.signature"

      %{token: token}
    end

    test "rejects when JwksCache returns :not_loaded", %{token: token} do
      conn =
        conn(:get, "/anything")
        |> put_req_header("authorization", "Bearer #{token}")
        |> run()

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "rejects when JwksCache returns a generic error", %{token: token} do
      with_mock JwksCache, [:passthrough],
        get_signing_key: fn _ -> {:error, :something_else} end do
        conn =
          conn(:get, "/anything")
          |> put_req_header("authorization", "Bearer #{token}")
          |> run()

        refute Map.has_key?(conn.assigns, :user_id)
      end
    end

    test "rejects when JwksCache provides a key but the signature is invalid",
         %{token: token} do
      # Use a real (but unrelated) PEM so validate_token reaches Joken.verify_and_validate
      pem = generate_ec_pem()

      with_mock JwksCache, [:passthrough], get_signing_key: fn _ -> {:ok, pem} end do
        conn =
          conn(:get, "/anything")
          |> put_req_header("authorization", "Bearer #{token}")
          |> run()

        refute Map.has_key?(conn.assigns, :user_id)
      end
    end
  end

  defp generate_ec_pem do
    jwk = JOSE.JWK.generate_key({:ec, "P-256"})
    {_, pem} = JOSE.JWK.to_pem(jwk)
    pem
  end
end
