defmodule WhisprMessaging.RepoTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Repo

  describe "health_check/0" do
    test "returns :ok when the database is reachable" do
      assert Repo.health_check() == :ok
    end
  end

  describe "connection_info/0" do
    test "returns a Postgrex.Result describing the current connection" do
      result = Repo.connection_info()
      assert %Postgrex.Result{} = result
      assert result.num_rows >= 1
      assert Enum.member?(result.columns, "database")
      assert Enum.member?(result.columns, "version")
    end
  end

  describe "safe_query/3" do
    test "wraps a successful query in {:ok, result}" do
      assert {:ok, %Postgrex.Result{rows: rows}} = Repo.safe_query("SELECT 1", [], log: false)
      assert rows == [[1]]
    end

    test "returns {:error, exception} on a malformed query" do
      assert {:error, exception} = Repo.safe_query("INVALID SQL", [], log: false)
      assert is_exception(exception)
    end
  end

  describe "safe_transact/1" do
    test "commits when the function returns normally" do
      assert {:ok, 42} = Repo.safe_transact(fn -> 42 end)
    end

    test "rolls back when the function raises" do
      assert {:error, exception} =
               Repo.safe_transact(fn ->
                 raise "boom"
               end)

      assert is_exception(exception)
      assert Exception.message(exception) =~ "boom"
    end
  end
end
