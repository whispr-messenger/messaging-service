defmodule WhisprMessagingWeb.UserSocketTest do
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  alias WhisprMessagingWeb.UserSocket

  @endpoint WhisprMessagingWeb.Endpoint

  describe "connect/3" do
    test "accepts a valid test token and assigns the user_id" do
      uid = Ecto.UUID.generate()

      assert {:ok, socket} = connect(UserSocket, %{"token" => "test_token_#{uid}"})
      assert socket.assigns.user_id == uid
    end

    test "rejects connections without a token" do
      assert :error == connect(UserSocket, %{})
    end

    test "rejects connections with an empty token" do
      assert :error == connect(UserSocket, %{"token" => ""})
    end

    test "rejects connections with an invalid token" do
      assert :error == connect(UserSocket, %{"token" => "not.a.real.jwt"})
    end

    test "rejects a JWT whose header has no kid (WHISPR-1239)" do
      # Header sans kid -> peek_kid renvoie {:error, :missing_kid} -> connect :error
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT"})
      assert :error == connect(UserSocket, %{"token" => token})
    end

    test "rejects a JWT whose header has an empty kid (WHISPR-1239)" do
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT", "kid" => ""})
      assert :error == connect(UserSocket, %{"token" => token})
    end

    test "rejects a JWT whose kid is unknown to the JWKS cache (WHISPR-1239)" do
      # Header valide avec kid mais inconnu du cache -> :not_loaded -> :error
      token = forge_jwt(%{"alg" => "ES256", "typ" => "JWT", "kid" => "kid-absent-du-cache"})
      assert :error == connect(UserSocket, %{"token" => token})
    end
  end

  # Construit un JWT structurellement valide (3 segments base64url) avec un
  # header arbitraire. Le payload et la signature sont des placeholders ;
  # on s'arrete avant la verification cryptographique dans ces tests.
  defp forge_jwt(header_map) do
    header = header_map |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload = %{"sub" => "user-1"} |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = Base.url_encode64("fake-sig", padding: false)
    "#{header}.#{payload}.#{signature}"
  end

  describe "id/1" do
    test "returns the deterministic socket id format" do
      uid = Ecto.UUID.generate()
      {:ok, socket} = connect(UserSocket, %{"token" => "test_token_#{uid}"})
      assert UserSocket.id(socket) == "user_socket:#{uid}"
    end
  end

  describe "valid_aud?/1 (WHISPR-1214)" do
    test "accepts nil — current access tokens carry no aud claim" do
      assert UserSocket.valid_aud?(nil)
    end

    test "accepts the historical HTTP audience" do
      assert UserSocket.valid_aud?("whispr")
    end

    test "accepts the new short-lived WS audience" do
      assert UserSocket.valid_aud?("ws")
    end

    test "rejects any other audience string" do
      refute UserSocket.valid_aud?("api")
      refute UserSocket.valid_aud?("")
      refute UserSocket.valid_aud?("WS")
    end

    test "rejects non-string types" do
      refute UserSocket.valid_aud?(["whispr"])
      refute UserSocket.valid_aud?(123)
      refute UserSocket.valid_aud?(%{})
    end
  end
end
