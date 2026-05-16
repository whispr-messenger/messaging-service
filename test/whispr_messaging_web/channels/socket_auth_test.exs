defmodule WhisprMessagingWeb.SocketAuthTest do
  @moduledoc """
  Unit tests for the pure JWT helpers extracted from `UserSocket`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.SocketAuth

  describe "peek_kid/1" do
    test "returns the kid for a valid header" do
      header = %{"alg" => "ES256", "kid" => "key-1", "typ" => "JWT"}
      encoded = header |> Jason.encode!() |> Base.url_encode64(padding: false)
      token = encoded <> ".body.sig"

      assert SocketAuth.peek_kid(token) == "key-1"
    end

    test "returns nil when the header is missing the kid" do
      header = %{"alg" => "ES256", "typ" => "JWT"}
      encoded = header |> Jason.encode!() |> Base.url_encode64(padding: false)
      token = encoded <> ".body.sig"

      assert SocketAuth.peek_kid(token) == nil
    end

    test "returns nil when kid is not a binary" do
      header = %{"alg" => "ES256", "kid" => 42}
      encoded = header |> Jason.encode!() |> Base.url_encode64(padding: false)
      token = encoded <> ".body.sig"

      assert SocketAuth.peek_kid(token) == nil
    end

    test "returns nil when the header is not valid Base64" do
      assert SocketAuth.peek_kid("!!not_base64!!.body.sig") == nil
    end

    test "returns nil when the JSON in the header is malformed" do
      bad = Base.url_encode64("{not json", padding: false)
      assert SocketAuth.peek_kid(bad <> ".body.sig") == nil
    end

    test "returns nil for a non-binary input" do
      assert SocketAuth.peek_kid(nil) == nil
      assert SocketAuth.peek_kid(42) == nil
    end

    test "returns nil for an empty string (no dot, no header)" do
      assert SocketAuth.peek_kid("") == nil
    end
  end

  describe "valid_aud?/1" do
    test "nil is accepted (HTTP access tokens without aud)" do
      assert SocketAuth.valid_aud?(nil)
    end

    test "whispr and ws are accepted" do
      assert SocketAuth.valid_aud?("whispr")
      assert SocketAuth.valid_aud?("ws")
    end

    test "any other string is rejected" do
      refute SocketAuth.valid_aud?("hacker")
      refute SocketAuth.valid_aud?("")
    end

    test "non-strings are rejected" do
      refute SocketAuth.valid_aud?(42)
      refute SocketAuth.valid_aud?(%{})
      refute SocketAuth.valid_aud?([:list])
    end
  end

  describe "extract_sub/1" do
    test "returns {:ok, sub} when sub is a non-empty binary" do
      assert SocketAuth.extract_sub(%{"sub" => "u-1"}) == {:ok, "u-1"}
    end

    test "rejects an empty sub" do
      assert {:error, _} = SocketAuth.extract_sub(%{"sub" => ""})
    end

    test "rejects a missing sub" do
      assert {:error, _} = SocketAuth.extract_sub(%{})
    end

    test "rejects a non-string sub" do
      assert {:error, _} = SocketAuth.extract_sub(%{"sub" => 42})
    end
  end
end
