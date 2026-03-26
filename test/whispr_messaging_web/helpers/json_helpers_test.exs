defmodule WhisprMessagingWeb.JsonHelpersTest do
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.JsonHelpers

  describe "camelize_keys/1" do
    test "converts atom keys to camelCase strings" do
      input = %{conversation_id: "abc", sender_id: "def"}
      expected = %{"conversationId" => "abc", "senderId" => "def"}
      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "converts string keys to camelCase" do
      input = %{"message_type" => "text", "is_deleted" => false}
      expected = %{"messageType" => "text", "isDeleted" => false}
      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "handles single-word keys without change" do
      input = %{id: "uuid", type: "direct", content: "hello"}
      expected = %{"id" => "uuid", "type" => "direct", "content" => "hello"}
      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "recursively converts nested maps" do
      input = %{
        data: %{
          conversation_id: "abc",
          sender_id: "def"
        }
      }

      expected = %{
        "data" => %{
          "conversationId" => "abc",
          "senderId" => "def"
        }
      }

      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "recursively converts maps in lists" do
      input = %{
        members: [
          %{user_id: "abc", is_active: true},
          %{user_id: "def", is_active: false}
        ]
      }

      expected = %{
        "members" => [
          %{"userId" => "abc", "isActive" => true},
          %{"userId" => "def", "isActive" => false}
        ]
      }

      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "handles multi-segment snake_case keys" do
      input = %{delete_for_everyone: true, external_group_id: "ext-123"}

      expected = %{
        "deleteForEveryone" => true,
        "externalGroupId" => "ext-123"
      }

      assert JsonHelpers.camelize_keys(input) == expected
    end

    test "preserves non-map, non-list values" do
      assert JsonHelpers.camelize_keys("string") == "string"
      assert JsonHelpers.camelize_keys(42) == 42
      assert JsonHelpers.camelize_keys(nil) == nil
    end

    test "handles empty map" do
      assert JsonHelpers.camelize_keys(%{}) == %{}
    end

    test "handles empty list" do
      assert JsonHelpers.camelize_keys([]) == []
    end

    test "converts list of maps" do
      input = [%{user_id: "a"}, %{user_id: "b"}]
      expected = [%{"userId" => "a"}, %{"userId" => "b"}]
      assert JsonHelpers.camelize_keys(input) == expected
    end
  end
end
