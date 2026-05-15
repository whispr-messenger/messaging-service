defmodule WhisprMessagingWeb.MessageRenderingTest do
  @moduledoc """
  Unit tests for the rendering and parsing helpers extracted from
  `MessageController`.
  """
  use ExUnit.Case, async: true

  alias WhisprMessagingWeb.MessageRendering

  defp build_message(attrs \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      sender_id: Ecto.UUID.generate(),
      content: "encrypted",
      message_type: "text",
      metadata: %{},
      reply_to_id: nil,
      forwarded_from_id: nil,
      edited_at: nil,
      is_deleted: false,
      expires_at: nil,
      sent_at: ~U[2026-05-01 12:00:00Z],
      inserted_at: ~N[2026-05-01 12:00:00],
      updated_at: ~N[2026-05-01 12:00:00]
    }

    Map.merge(base, Map.new(attrs))
  end

  describe "render_message/1" do
    test "renders basic fields with delivery_status='sent' when no statuses" do
      out = MessageRendering.render_message(build_message())
      assert out["deliveryStatus"] == "sent"
      assert out["isEdited"] == false
      assert out["isDeleted"] == false
      assert out["isEphemeral"] == false
    end

    test "renders is_edited=true when edited_at is set" do
      out = MessageRendering.render_message(build_message(edited_at: ~U[2026-05-02 12:00:00Z]))
      assert out["isEdited"] == true
    end

    test "renders is_ephemeral=true when expires_at is set" do
      out = MessageRendering.render_message(build_message(expires_at: ~U[2026-06-01 00:00:00Z]))
      assert out["isEphemeral"] == true
    end

    test "computes aggregate delivery_status from preloaded delivery_statuses" do
      statuses = [
        %WhisprMessaging.Messages.DeliveryStatus{
          delivered_at: ~U[2026-05-01 12:00:00Z],
          read_at: nil
        },
        %WhisprMessaging.Messages.DeliveryStatus{
          delivered_at: ~U[2026-05-01 12:00:00Z],
          read_at: ~U[2026-05-01 12:01:00Z]
        }
      ]

      out =
        MessageRendering.render_message(
          Map.put(build_message(), :delivery_statuses, statuses)
        )

      assert out["deliveryStatus"] == "delivered"
    end

    test "embeds reply_to when present" do
      parent = %WhisprMessaging.Messages.Message{
        id: Ecto.UUID.generate(),
        sender_id: Ecto.UUID.generate(),
        content: "parent",
        message_type: "text",
        is_deleted: false
      }

      out = MessageRendering.render_message(Map.put(build_message(), :reply_to, parent))
      assert out["replyTo"]["content"] == "parent"
    end
  end

  describe "render_messages/1" do
    test "renders each message in the list" do
      assert MessageRendering.render_messages([build_message(), build_message()]) |> length() == 2
    end
  end

  describe "render_reply_context/1" do
    test "exposes id, content, message_type, is_deleted" do
      msg = build_message(message_type: "text")
      out = MessageRendering.render_reply_context(msg)
      assert out.id == msg.id
      assert out.message_type == "text"
      assert out.is_deleted == false
    end
  end

  describe "safe_binary_content/1" do
    test "nil → nil" do
      assert MessageRendering.safe_binary_content(nil) == nil
    end

    test "valid UTF-8 → same binary" do
      assert MessageRendering.safe_binary_content("hello") == "hello"
    end

    test "non-UTF-8 → Base64-encoded" do
      raw = <<0xFF, 0xFE, 0xFD>>
      assert MessageRendering.safe_binary_content(raw) == Base.encode64(raw)
    end

    test "non-binary → to_string fallback" do
      assert MessageRendering.safe_binary_content(:atom) == "atom"
      assert MessageRendering.safe_binary_content(42) == "42"
    end
  end

  describe "resolve_ttl_seconds/1" do
    test "keeps params unchanged when expires_at is already set" do
      params = %{"expires_at" => ~U[2026-06-01 00:00:00Z]}
      assert MessageRendering.resolve_ttl_seconds(params) == params
    end

    test "converts ttl_seconds to expires_at" do
      out = MessageRendering.resolve_ttl_seconds(%{"ttl_seconds" => 60})
      assert out["expires_at"] != nil
      refute Map.has_key?(out, "ttl_seconds")
    end

    test "ignores zero or negative ttl_seconds" do
      assert MessageRendering.resolve_ttl_seconds(%{"ttl_seconds" => 0}) == %{"ttl_seconds" => 0}
      assert MessageRendering.resolve_ttl_seconds(%{"ttl_seconds" => -10}) == %{"ttl_seconds" => -10}
    end

    test "no-op for unrelated params" do
      assert MessageRendering.resolve_ttl_seconds(%{"foo" => "bar"}) == %{"foo" => "bar"}
    end
  end

  describe "build_truncated_preview/2" do
    test "returns nil when preview is nil" do
      assert MessageRendering.build_truncated_preview(nil, "x") == nil
    end

    test "returns preview untouched when short enough" do
      assert MessageRendering.build_truncated_preview("short", "x") == "short"
    end

    test "clips around the first match (case-insensitive)" do
      long = String.duplicate("a", 50) <> "NEEDLE" <> String.duplicate("b", 50)
      out = MessageRendering.build_truncated_preview(long, "needle")
      assert byte_size(out) <= 100
      assert String.contains?(out, "NEEDLE")
    end

    test "clips from the start when no match" do
      long = String.duplicate("a", 200)
      out = MessageRendering.build_truncated_preview(long, "needle")
      assert byte_size(out) == 100
    end
  end

  describe "maybe_put_opt/3" do
    test "appends a non-nil non-empty value" do
      assert MessageRendering.maybe_put_opt([], :k, "v") == [k: "v"]
    end

    test "drops nil and empty values" do
      assert MessageRendering.maybe_put_opt([], :k, nil) == []
      assert MessageRendering.maybe_put_opt([], :k, "") == []
    end
  end

  describe "parse_int/2" do
    test "returns integer as-is" do
      assert MessageRendering.parse_int(42, 0) == 42
    end

    test "parses binary integers" do
      assert MessageRendering.parse_int("10", 0) == 10
    end

    test "falls back to default on invalid binary" do
      assert MessageRendering.parse_int("not_int", 5) == 5
    end

    test "falls back to default for other types" do
      assert MessageRendering.parse_int(nil, 7) == 7
      assert MessageRendering.parse_int([], 9) == 9
    end
  end

  describe "ensure_receipt_user/1" do
    test ":unauthorized for nil" do
      assert MessageRendering.ensure_receipt_user(nil) == :unauthorized
    end

    test ":ok for any user_id" do
      assert MessageRendering.ensure_receipt_user(Ecto.UUID.generate()) == :ok
    end
  end

  describe "valid_receipt_status/1" do
    test "accepts 'delivered' and 'read'" do
      assert MessageRendering.valid_receipt_status("delivered")
      assert MessageRendering.valid_receipt_status("read")
    end

    test "rejects anything else" do
      refute MessageRendering.valid_receipt_status("seen")
      refute MessageRendering.valid_receipt_status(nil)
      refute MessageRendering.valid_receipt_status(:read)
    end
  end
end
