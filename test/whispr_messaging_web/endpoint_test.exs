defmodule WhisprMessagingWeb.EndpointTest do
  @moduledoc """
  Tests for endpoint-level helpers (WHISPR-839 WebSocket origin check).
  """

  use ExUnit.Case, async: false

  alias WhisprMessagingWeb.Endpoint

  setup do
    original_env = Application.get_env(:whispr_messaging, :env)
    original_cors = System.get_env("CORS_ALLOWED_ORIGINS")

    on_exit(fn ->
      case original_env do
        nil -> Application.delete_env(:whispr_messaging, :env)
        value -> Application.put_env(:whispr_messaging, :env, value)
      end

      case original_cors do
        nil -> System.delete_env("CORS_ALLOWED_ORIGINS")
        value -> System.put_env("CORS_ALLOWED_ORIGINS", value)
      end
    end)

    :ok
  end

  describe "ws_check_origin/1 in non-prod" do
    test "permits any origin in test env" do
      Application.put_env(:whispr_messaging, :env, :test)

      assert Endpoint.ws_check_origin(URI.parse("https://anywhere.example.com")) == true
    end
  end

  describe "ws_check_origin/1 in prod" do
    setup do
      Application.put_env(:whispr_messaging, :env, :prod)
      :ok
    end

    test "raises if CORS_ALLOWED_ORIGINS is unset" do
      System.delete_env("CORS_ALLOWED_ORIGINS")

      assert_raise RuntimeError, ~r/must be set in production/, fn ->
        Endpoint.ws_check_origin(URI.parse("https://app.example.com"))
      end
    end

    test "raises if CORS_ALLOWED_ORIGINS is empty" do
      System.put_env("CORS_ALLOWED_ORIGINS", "")

      assert_raise RuntimeError, ~r/cannot be empty in production/, fn ->
        Endpoint.ws_check_origin(URI.parse("https://app.example.com"))
      end
    end

    test "raises if CORS_ALLOWED_ORIGINS is a bare wildcard" do
      System.put_env("CORS_ALLOWED_ORIGINS", "*")

      assert_raise RuntimeError, ~r/CORS_ALLOWED_ORIGINS=\* is not allowed/, fn ->
        Endpoint.ws_check_origin(URI.parse("https://app.example.com"))
      end
    end

    test "accepts an origin present in the allowlist" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com,https://admin.example.com")

      assert Endpoint.ws_check_origin(URI.parse("https://app.example.com")) == true
    end

    test "rejects an origin not in the allowlist" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com")

      assert Endpoint.ws_check_origin(URI.parse("https://evil.example.com")) == false
    end

    test "trims whitespace in the allowlist" do
      System.put_env("CORS_ALLOWED_ORIGINS", " https://a.test , https://b.test ")

      assert Endpoint.ws_check_origin(URI.parse("https://b.test")) == true
    end

    test "treats default https port as canonical" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com")

      assert Endpoint.ws_check_origin(URI.parse("https://app.example.com:443")) == true
    end
  end
end
