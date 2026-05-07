defmodule WhisprMessagingWeb.Plugs.ForwardedPrefixTest do
  @moduledoc """
  Tests for the ForwardedPrefix plug. Verifies that the `location` response
  header is rewritten only when the upstream proxy injects an
  `x-forwarded-prefix` header AND the response is a relative URL.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Phoenix.ConnTest

  alias WhisprMessagingWeb.Plugs.ForwardedPrefix

  defp send_with_location(conn, location) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  describe "init/1" do
    test "is the identity on its options" do
      assert ForwardedPrefix.init([]) == []
      assert ForwardedPrefix.init(foo: 1) == [foo: 1]
    end
  end

  describe "call/2" do
    test "prepends the prefix on relative locations" do
      conn =
        build_conn(:get, "/swagger")
        |> put_req_header("x-forwarded-prefix", "/messaging")
        |> ForwardedPrefix.call([])
        |> send_with_location("/api/swagger/index.html")

      assert ["/messaging/api/swagger/index.html"] = get_resp_header(conn, "location")
    end

    test "trims a trailing slash on the prefix" do
      conn =
        build_conn(:get, "/x")
        |> put_req_header("x-forwarded-prefix", "/messaging/")
        |> ForwardedPrefix.call([])
        |> send_with_location("/x")

      assert ["/messaging/x"] = get_resp_header(conn, "location")
    end

    test "leaves absolute URLs untouched" do
      conn =
        build_conn(:get, "/x")
        |> put_req_header("x-forwarded-prefix", "/messaging")
        |> ForwardedPrefix.call([])
        |> send_with_location("https://example.com/foo")

      assert ["https://example.com/foo"] = get_resp_header(conn, "location")
    end

    test "leaves already-prefixed paths untouched" do
      conn =
        build_conn(:get, "/x")
        |> put_req_header("x-forwarded-prefix", "/messaging")
        |> ForwardedPrefix.call([])
        |> send_with_location("/messaging/already")

      assert ["/messaging/already"] = get_resp_header(conn, "location")
    end

    test "is a no-op when the prefix header is absent" do
      conn =
        build_conn(:get, "/x")
        |> ForwardedPrefix.call([])
        |> send_with_location("/api/x")

      assert ["/api/x"] = get_resp_header(conn, "location")
    end

    test "is a no-op when the prefix header is empty" do
      conn =
        build_conn(:get, "/x")
        |> put_req_header("x-forwarded-prefix", "")
        |> ForwardedPrefix.call([])
        |> send_with_location("/api/x")

      assert ["/api/x"] = get_resp_header(conn, "location")
    end

    test "leaves the response untouched when no location is set" do
      conn =
        build_conn(:get, "/x")
        |> put_req_header("x-forwarded-prefix", "/messaging")
        |> ForwardedPrefix.call([])
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "location") == []
    end
  end
end
