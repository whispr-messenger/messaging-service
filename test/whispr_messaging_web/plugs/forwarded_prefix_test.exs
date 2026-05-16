defmodule WhisprMessagingWeb.Plugs.ForwardedPrefixTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias WhisprMessagingWeb.Plugs.ForwardedPrefix

  defp build(prefix) do
    base = conn(:get, "/swagger")
    if prefix, do: put_req_header(base, "x-forwarded-prefix", prefix), else: base
  end

  defp run(conn, location \\ "/api/swagger/index.html") do
    conn = ForwardedPrefix.call(conn, ForwardedPrefix.init([]))

    conn
    |> put_resp_header("location", location)
    |> send_resp(302, "")
  end

  describe "init/1" do
    test "echoes the options" do
      assert ForwardedPrefix.init([]) == []
      assert ForwardedPrefix.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2 with no x-forwarded-prefix" do
    test "does not alter the location header" do
      conn = run(build(nil), "/foo")
      assert get_resp_header(conn, "location") == ["/foo"]
    end

    test "ignores an empty prefix" do
      conn = run(build(""), "/foo")
      assert get_resp_header(conn, "location") == ["/foo"]
    end
  end

  describe "call/2 with a prefix" do
    test "prepends the prefix to a relative location" do
      conn = run(build("/messaging"), "/api/swagger/index.html")
      assert get_resp_header(conn, "location") == ["/messaging/api/swagger/index.html"]
    end

    test "trims trailing slashes from the prefix" do
      conn = run(build("/messaging/"), "/api/swagger")
      assert get_resp_header(conn, "location") == ["/messaging/api/swagger"]
    end

    test "leaves an absolute http URL alone" do
      conn = run(build("/messaging"), "http://example.com/x")
      assert get_resp_header(conn, "location") == ["http://example.com/x"]
    end

    test "leaves an absolute https URL alone" do
      conn = run(build("/messaging"), "https://example.com/y")
      assert get_resp_header(conn, "location") == ["https://example.com/y"]
    end

    test "is idempotent when the path already starts with the prefix" do
      conn = run(build("/messaging"), "/messaging/api/swagger")
      assert get_resp_header(conn, "location") == ["/messaging/api/swagger"]
    end

    test "does not touch responses without a location header" do
      conn = ForwardedPrefix.call(build("/messaging"), ForwardedPrefix.init([]))
      conn = send_resp(conn, 200, "ok")
      assert get_resp_header(conn, "location") == []
    end
  end
end
