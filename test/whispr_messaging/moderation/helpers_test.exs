defmodule WhisprMessaging.Moderation.HelpersTest do
  use ExUnit.Case, async: true

  alias WhisprMessaging.Moderation.Helpers

  describe "tap_ok/2" do
    test "calls fun for {:ok, value} and returns the original result" do
      pid = self()

      result =
        Helpers.tap_ok({:ok, :value}, fn v ->
          send(pid, {:tapped, v})
        end)

      assert result == {:ok, :value}
      assert_receive {:tapped, :value}
    end

    test "passes errors through without invoking fun" do
      Helpers.tap_ok({:error, :reason}, fn _ -> flunk("fun should not be called on error") end)
    end

    test "passes any non-ok tuple through" do
      assert Helpers.tap_ok(:bare, fn _ -> :unused end) == :bare
    end
  end

  describe "redis_publish/2" do
    test "publishes to redis and returns the result" do
      result = Helpers.redis_publish("whispr:test:helpers", "ping")
      assert match?({:ok, _}, result) or result == nil
    end
  end
end
