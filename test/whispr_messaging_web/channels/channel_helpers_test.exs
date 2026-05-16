defmodule WhisprMessagingWeb.ChannelHelpersTest do
  @moduledoc """
  Unit tests for the pure helpers extracted from `ConversationChannel`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessaging.Messages.Message
  alias WhisprMessagingWeb.ChannelHelpers

  describe "safe_binary_content/1" do
    test "nil → nil" do
      assert ChannelHelpers.safe_binary_content(nil) == nil
    end

    test "valid UTF-8 → same binary" do
      assert ChannelHelpers.safe_binary_content("hello") == "hello"
      assert ChannelHelpers.safe_binary_content("hé llo 🌍") == "hé llo 🌍"
    end

    test "non-UTF-8 binary → Base64-encoded" do
      raw = <<255, 254, 253>>
      assert ChannelHelpers.safe_binary_content(raw) == Base.encode64(raw)
    end

    test "integer → string via to_string/1" do
      assert ChannelHelpers.safe_binary_content(42) == "42"
    end

    test "atom → string via to_string/1" do
      assert ChannelHelpers.safe_binary_content(:hello) == "hello"
    end
  end

  describe "maybe_put/3" do
    test "nil value → map unchanged" do
      assert ChannelHelpers.maybe_put(%{a: 1}, :b, nil) == %{a: 1}
    end

    test "non-nil value → key inserted" do
      assert ChannelHelpers.maybe_put(%{a: 1}, :b, 2) == %{a: 1, b: 2}
    end

    test "starts from empty map" do
      assert ChannelHelpers.maybe_put(%{}, :k, "v") == %{k: "v"}
    end

    test "false is not nil → inserted" do
      assert ChannelHelpers.maybe_put(%{}, :k, false) == %{k: false}
    end
  end

  describe "serialize_reply_context/1" do
    test "exposes the compact reply-context payload" do
      parent = %Message{
        id: "msg-1",
        sender_id: "u-1",
        content: "hello",
        message_type: "text",
        is_deleted: false
      }

      out = ChannelHelpers.serialize_reply_context(parent)
      assert out.id == "msg-1"
      assert out.sender_id == "u-1"
      assert out.content == "hello"
      assert out.message_type == "text"
      assert out.is_deleted == false
    end

    test "applies safe_binary_content to non-UTF-8 content" do
      raw = <<200, 201, 202>>

      parent = %Message{
        id: "msg-2",
        sender_id: "u-1",
        content: raw,
        message_type: "text",
        is_deleted: false
      }

      out = ChannelHelpers.serialize_reply_context(parent)
      assert out.content == Base.encode64(raw)
    end
  end

  describe "serialize_reaction/1" do
    test "shapes a reaction map into camelCase JSON payload" do
      reaction = %{
        id: "r-1",
        message_id: "m-1",
        user_id: "u-1",
        reaction: "👍",
        inserted_at: ~N[2026-05-01 00:00:00]
      }

      out = ChannelHelpers.serialize_reaction(reaction)
      assert out["id"] == "r-1"
      assert out["messageId"] == "m-1"
      assert out["userId"] == "u-1"
      assert out["reaction"] == "👍"
    end
  end

  describe "format_changeset_errors/1" do
    test "interpolates {key} placeholders from opts" do
      types = %{title: :string}

      changeset =
        Ecto.Changeset.cast({%{}, types}, %{title: "ab"}, [:title])
        |> Ecto.Changeset.validate_length(:title, min: 5)

      %{title: [msg | _]} = ChannelHelpers.format_changeset_errors(changeset)
      assert msg =~ "5"
    end

    test "handles required field validation" do
      types = %{title: :string}

      changeset =
        Ecto.Changeset.cast({%{}, types}, %{}, [:title])
        |> Ecto.Changeset.validate_required([:title])

      errors = ChannelHelpers.format_changeset_errors(changeset)
      assert Map.has_key?(errors, :title)
    end
  end
end
