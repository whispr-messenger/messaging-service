defmodule WhisprMessaging.CacheTest do
  @moduledoc """
  Tests for the Redis-backed cache wrapper.
  Requires the `:redix` connection to be running (started by the supervisor).
  """

  use ExUnit.Case, async: false

  alias WhisprMessaging.Cache

  setup do
    # Each test uses a unique key prefix to avoid clashes
    prefix = "cache-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.invalidate_pattern("#{prefix}*") end)
    %{prefix: prefix}
  end

  describe "set/2 and get/1" do
    test "round-trips a JSON-serialisable map", %{prefix: prefix} do
      key = "#{prefix}:user"
      assert :ok = Cache.set(key, %{name: "alice", age: 30})
      assert {:ok, %{"name" => "alice", "age" => 30}} = Cache.get(key)
    end

    test "returns {:error, :not_found} for missing key", %{prefix: prefix} do
      assert {:error, :not_found} = Cache.get("#{prefix}:missing")
    end

    test "supports primitive values via JSON encoding", %{prefix: prefix} do
      key = "#{prefix}:int"
      assert :ok = Cache.set(key, 42)
      assert {:ok, 42} = Cache.get(key)
    end
  end

  describe "delete/1" do
    test "removes a previously set key", %{prefix: prefix} do
      key = "#{prefix}:to-delete"
      :ok = Cache.set(key, "x")
      assert :ok = Cache.delete(key)
      assert {:error, :not_found} = Cache.get(key)
    end
  end

  describe "fetch/3" do
    test "returns the cached value when present (cache hit)", %{prefix: prefix} do
      key = "#{prefix}:fetch-hit"
      :ok = Cache.set(key, %{cached: true})

      assert {:ok, %{"cached" => true}} =
               Cache.fetch(key, fn -> {:ok, %{cached: false}} end)
    end

    test "evaluates fallback and caches its result on miss", %{prefix: prefix} do
      key = "#{prefix}:fetch-miss"

      assert {:ok, %{generated: true}} =
               Cache.fetch(key, fn -> {:ok, %{generated: true}} end)

      assert {:ok, %{"generated" => true}} = Cache.get(key)
    end

    test "propagates fallback errors without caching", %{prefix: prefix} do
      key = "#{prefix}:fetch-error"

      assert {:error, :boom} = Cache.fetch(key, fn -> {:error, :boom} end)
      assert {:error, :not_found} = Cache.get(key)
    end
  end

  describe "invalidate_pattern/1" do
    test "deletes all matching keys", %{prefix: prefix} do
      :ok = Cache.set("#{prefix}:a", 1)
      :ok = Cache.set("#{prefix}:b", 2)
      :ok = Cache.set("#{prefix}:c", 3)

      assert :ok = Cache.invalidate_pattern("#{prefix}*")

      assert {:error, :not_found} = Cache.get("#{prefix}:a")
      assert {:error, :not_found} = Cache.get("#{prefix}:b")
      assert {:error, :not_found} = Cache.get("#{prefix}:c")
    end

    test "is a no-op when no keys match", %{prefix: prefix} do
      assert :ok = Cache.invalidate_pattern("#{prefix}:none*")
    end
  end

  describe "key helpers" do
    test "build the expected stable strings" do
      assert Cache.conversation_key("conv-1") == "conversation:conv-1"
      assert Cache.message_key("msg-1") == "message:msg-1"
      assert Cache.user_conversations_key("u-1") == "user:u-1:conversations"
      assert Cache.conversation_messages_key("c-1") == "conversation:c-1:messages"
    end
  end
end
