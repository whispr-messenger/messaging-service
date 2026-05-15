defmodule WhisprMessagingWeb.Plugs.RequireAdminTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias WhisprMessagingWeb.Plugs.RequireAdmin

  defp run(conn) do
    RequireAdmin.call(conn, RequireAdmin.init([]))
  end

  describe "in :test env" do
    test "allows the request when user_id is assigned" do
      conn =
        conn(:get, "/anything")
        |> assign(:user_id, "u-1")
        |> run()

      refute conn.halted
      assert conn.assigns.user_role == "admin"
    end

    test "returns 403 when no user_id is assigned" do
      conn = run(conn(:get, "/anything"))
      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "init/1" do
    test "echoes the options" do
      assert RequireAdmin.init([]) == []
      assert RequireAdmin.init(foo: :bar) == [foo: :bar]
    end
  end
end
