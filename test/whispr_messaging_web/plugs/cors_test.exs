defmodule WhisprMessagingWeb.Plugs.CorsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias WhisprMessagingWeb.Plugs.Cors

  @opts Cors.init([])

  setup do
    original = System.get_env("CORS_ALLOWED_ORIGINS")

    # Reset the per-process "already warned" flag so each test sees the
    # warning pathway independently.
    Process.delete(:whispr_cors_warn_logged)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("CORS_ALLOWED_ORIGINS")
        value -> System.put_env("CORS_ALLOWED_ORIGINS", value)
      end
    end)

    :ok
  end

  defp call(method, headers \\ []) do
    conn = conn(method, "/whatever")

    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> Cors.call(@opts)
  end

  describe "fail-closed default" do
    test "emits no CORS headers when CORS_ALLOWED_ORIGINS is unset" do
      System.delete_env("CORS_ALLOWED_ORIGINS")

      conn = call(:get, [{"origin", "https://evil.example.com"}])

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end

    test "emits no CORS headers when CORS_ALLOWED_ORIGINS is empty" do
      System.put_env("CORS_ALLOWED_ORIGINS", "")

      conn = call(:get, [{"origin", "https://evil.example.com"}])

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "OPTIONS preflight still responds 204 without CORS headers when config is missing" do
      System.delete_env("CORS_ALLOWED_ORIGINS")

      conn = call(:options, [{"origin", "https://evil.example.com"}])

      assert conn.status == 204
      assert conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "explicit allowlist" do
    test "echoes back a matching origin and emits credentials header" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com,https://admin.example.com")

      conn = call(:get, [{"origin", "https://app.example.com"}])

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.com"]
      assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "trims whitespace around each entry" do
      System.put_env("CORS_ALLOWED_ORIGINS", " https://a.test , https://b.test ")

      conn = call(:get, [{"origin", "https://b.test"}])

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://b.test"]
    end

    test "does not echo back an origin that is not on the allowlist" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com")

      conn = call(:get, [{"origin", "https://evil.example.com"}])

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end

    test "does not emit credentials when the request has no origin" do
      System.put_env("CORS_ALLOWED_ORIGINS", "https://app.example.com")

      conn = call(:get, [])

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "wildcard mode" do
    test "emits '*' for any origin but NEVER emits allow-credentials" do
      System.put_env("CORS_ALLOWED_ORIGINS", "*")

      conn = call(:get, [{"origin", "https://anywhere.example.com"}])

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end

    test "OPTIONS preflight returns 204 with the wildcard origin" do
      System.put_env("CORS_ALLOWED_ORIGINS", "*")

      conn = call(:options, [{"origin", "https://anywhere.example.com"}])

      assert conn.status == 204
      assert conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end
  end
end
