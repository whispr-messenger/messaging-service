defmodule WhisprMessaging.CacheTest do
  use ExUnit.Case, async: false

  alias WhisprMessaging.Cache

  @moduletag :integration

  setup do
    {:ok, _} = Redix.command(:redix, ["FLUSHDB"])
    :ok
  end

  describe "set/3 and get/1" do
    test "stores and retrieves a string value" do
      assert :ok = Cache.set("k1", "hello")
      assert {:ok, "hello"} = Cache.get("k1")
    end

    test "stores and retrieves a map value via JSON" do
      assert :ok = Cache.set("k2", %{"a" => 1, "b" => [2, 3]})
      assert {:ok, decoded} = Cache.get("k2")
      assert decoded == %{"a" => 1, "b" => [2, 3]}
    end

    test "honours TTL via SETEX" do
      assert :ok = Cache.set("k3", "ephemeral", 60)
      assert {:ok, "ephemeral"} = Cache.get("k3")

      # Verify the expiry is set
      assert {:ok, ttl} = Redix.command(:redix, ["TTL", "cache:k3"])
      assert is_integer(ttl) and ttl > 0
    end

    test "returns :not_found for missing key" do
      assert {:error, :not_found} = Cache.get("missing")
    end
  end

  describe "delete/1" do
    test "removes a previously set key" do
      :ok = Cache.set("to-del", "x")
      assert :ok = Cache.delete("to-del")
      assert {:error, :not_found} = Cache.get("to-del")
    end

    test "deleting an unset key is :ok (idempotent)" do
      assert :ok = Cache.delete("never-set")
    end
  end

  describe "fetch/3" do
    test "returns the cached value when present and does not call fallback" do
      :ok = Cache.set("cached", "from-cache")

      result =
        Cache.fetch("cached", fn ->
          flunk("fallback should not be called when cache is hit")
        end)

      assert result == {:ok, "from-cache"}
    end

    test "calls fallback on miss and caches the value" do
      ref = :counters.new(1, [])

      result =
        Cache.fetch("miss-key", fn ->
          :counters.add(ref, 1, 1)
          {:ok, "computed"}
        end)

      assert result == {:ok, "computed"}
      assert :counters.get(ref, 1) == 1

      # Second call should hit the cache
      result2 =
        Cache.fetch("miss-key", fn ->
          :counters.add(ref, 1, 1)
          {:ok, "computed2"}
        end)

      assert result2 == {:ok, "computed"}
      assert :counters.get(ref, 1) == 1
    end

    test "does not cache an error result from fallback" do
      result =
        Cache.fetch("error-key", fn ->
          {:error, :boom}
        end)

      assert result == {:error, :boom}
      assert {:error, :not_found} = Cache.get("error-key")
    end
  end

  describe "invalidate_pattern/1" do
    test "deletes all keys matching the pattern" do
      :ok = Cache.set("user:1:foo", "a")
      :ok = Cache.set("user:1:bar", "b")
      :ok = Cache.set("user:2:foo", "c")

      assert :ok = Cache.invalidate_pattern("user:1:*")
      assert {:error, :not_found} = Cache.get("user:1:foo")
      assert {:error, :not_found} = Cache.get("user:1:bar")
      assert {:ok, "c"} = Cache.get("user:2:foo")
    end

    test "no-ops when nothing matches" do
      assert :ok = Cache.invalidate_pattern("does-not-exist:*")
    end
  end

  describe "key builders" do
    test "conversation_key/1 prefixes with conversation:" do
      assert Cache.conversation_key("abc") == "conversation:abc"
    end

    test "message_key/1 prefixes with message:" do
      assert Cache.message_key("xyz") == "message:xyz"
    end

    test "user_conversations_key/1 builds user/conversations key" do
      assert Cache.user_conversations_key("u1") == "user:u1:conversations"
    end

    test "conversation_messages_key/1 builds conv messages key" do
      assert Cache.conversation_messages_key("c1") == "conversation:c1:messages"
    end
  end
end
