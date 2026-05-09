defmodule WhisprMessagingWeb.Plugs.AuthenticateTest do
  @moduledoc """
  Tests for the Authenticate plug. Exercises the trusted gateway header,
  the test-only Bearer token shortcut, and the unauthenticated fall-through
  behaviour.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias WhisprMessagingWeb.Plugs.Authenticate

  describe "init/1" do
    test "is the identity on its options" do
      assert Authenticate.init([]) == []
      assert Authenticate.init(foo: 1) == [foo: 1]
    end
  end

  describe "call/2" do
    test "assigns user_id from a non-empty x-user-id gateway header" do
      uid = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/")
        |> put_req_header("x-user-id", uid)
        |> Authenticate.call([])

      assert conn.assigns[:user_id] == uid
    end

    test "ignores an empty x-user-id and falls through to bearer token" do
      uid = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/")
        |> put_req_header("x-user-id", "")
        |> put_req_header("authorization", "Bearer test_token_#{uid}")
        |> Authenticate.call([])

      assert conn.assigns[:user_id] == uid
    end

    test "assigns user_id from the test bearer token format" do
      uid = Ecto.UUID.generate()

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer test_token_#{uid}")
        |> Authenticate.call([])

      assert conn.assigns[:user_id] == uid
    end

    test "leaves user_id unset when no headers are present" do
      conn =
        build_conn(:get, "/")
        |> Authenticate.call([])

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "leaves user_id unset for an unverifiable bearer token" do
      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer not.a.real.token")
        |> Authenticate.call([])

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "leaves user_id unset when bearer JWT header has no kid (WHISPR-1239)" do
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT"})

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Authenticate.call([])

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "leaves user_id unset when bearer JWT header has empty kid (WHISPR-1239)" do
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT", "kid" => ""})

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Authenticate.call([])

      refute Map.has_key?(conn.assigns, :user_id)
    end

    test "leaves user_id unset when bearer JWT kid is unknown (WHISPR-1239)" do
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT", "kid" => "kid-absent-du-cache"})

      conn =
        build_conn(:get, "/")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Authenticate.call([])

      refute Map.has_key?(conn.assigns, :user_id)
    end
  end

  # Construit un JWT structurellement valide avec header arbitraire.
  # Payload et signature sont des placeholders ; la verification cryptographique
  # n'est jamais atteinte dans ces tests (rejet en amont sur kid manquant /
  # cache vide).
  defp forge_jwt(header_map) do
    header = header_map |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload = %{"sub" => "user-1"} |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = Base.url_encode64("fake-sig", padding: false)
    "#{header}.#{payload}.#{signature}"
  end
end
