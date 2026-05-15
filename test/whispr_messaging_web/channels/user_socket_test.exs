defmodule WhisprMessagingWeb.UserSocketTest do
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.UserSocket

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

  describe "connect/3" do
    test "accepts a test_token_<user_id> token" do
      assert {:ok, socket} =
               UserSocket.connect(
                 %{"token" => "test_token_user-1"},
                 %Phoenix.Socket{},
                 %{}
               )

      assert socket.assigns.user_id == "user-1"
    end

    test "rejects when no token is provided" do
      assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    end

    test "rejects when token is an empty string" do
      assert :error = UserSocket.connect(%{"token" => ""}, %Phoenix.Socket{}, %{})
    end

    test "rejects when JWT is malformed (no kid)" do
      header = Base.url_encode64(Jason.encode!(%{"alg" => "ES256"}), padding: false)
      payload = Base.url_encode64(Jason.encode!(%{"sub" => "x"}), padding: false)
      token = "#{header}.#{payload}.sig"

      assert :error = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    end
  end

  describe "id/1" do
    test "returns user_socket:<user_id> based on assigns.user_id" do
      socket = %Phoenix.Socket{assigns: %{user_id: "alice"}}
      assert UserSocket.id(socket) == "user_socket:alice"
    end
  end

  describe "connect/3 — additional rejection branches" do
    test "rejects when no token key is present in the params" do
      assert :error = UserSocket.connect(%{"foo" => "bar"}, %Phoenix.Socket{}, %{})
    end

    test "rejects a Base64-decodable but malformed header" do
      # Header with no kid, payload empty, signature empty
      header = Base.url_encode64(Jason.encode!(%{"alg" => "ES256"}), padding: false)
      token = "#{header}..signature"

      assert :error = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    end

    test "rejects when the token has no dots at all" do
      assert :error =
               UserSocket.connect(%{"token" => "completely-broken"}, %Phoenix.Socket{}, %{})
    end
  end
end
