defmodule WhisprMessagingWeb.ConversationRenderingTest do
  @moduledoc """
  Unit tests for the pure rendering helpers extracted from
  `ConversationController`. Exercises every branch (settings present / absent,
  direct vs group, nil last_message vs valid, binary content UTF-8 vs raw).
  """
  use WhisprMessaging.DataCase, async: true

  alias WhisprMessaging.Conversations
  alias WhisprMessagingWeb.ConversationRendering

  defp build_conv(attrs \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      type: "direct",
      external_group_id: nil,
      metadata: %{"name" => "Test"},
      is_active: true,
      inserted_at: ~N[2026-05-01 12:00:00],
      updated_at: ~N[2026-05-02 12:00:00]
    }

    Map.merge(base, Map.new(attrs))
  end

  describe "render_conversation/2" do
    test "renders without member_info — flags default to false" do
      conv = build_conv()
      result = ConversationRendering.render_conversation(conv, nil)

      assert result["isMuted"] == false
      assert result["isPinned"] == false
      assert result["isArchived"] == false
      assert result["unreadCount"] == 0
    end

    test "surfaces user flags from :member_info" do
      member_info = %{
        settings: %{"is_muted" => true, "is_pinned" => true, "is_archived" => false}
      }

      conv = Map.put(build_conv(), :member_info, member_info)
      result = ConversationRendering.render_conversation(conv, nil)

      assert result["isMuted"] == true
      assert result["isPinned"] == true
      assert result["isArchived"] == false
    end

    test "uses empty settings when member_info.settings is nil" do
      member_info = %{settings: nil}
      conv = Map.put(build_conv(), :member_info, member_info)
      result = ConversationRendering.render_conversation(conv, nil)

      assert result["isMuted"] == false
    end

    test "surfaces unread_count and last_message" do
      conv =
        build_conv()
        |> Map.put(:unread_count, 5)
        |> Map.put(:last_message, %{
          id: Ecto.UUID.generate(),
          sender_id: Ecto.UUID.generate(),
          content: "hi",
          message_type: "text",
          sent_at: ~U[2026-05-01 12:00:00Z],
          is_deleted: false
        })

      result = ConversationRendering.render_conversation(conv, nil)

      assert result["unreadCount"] == 5
      assert result["lastMessage"]["content"] == "hi"
    end
  end

  describe "render_last_message/1" do
    test "returns nil when last_message is nil" do
      assert ConversationRendering.render_last_message(nil) == nil
    end

    test "renders the message with safe content" do
      msg = %{
        id: Ecto.UUID.generate(),
        sender_id: Ecto.UUID.generate(),
        content: "hello",
        message_type: "text",
        sent_at: ~U[2026-05-01 12:00:00Z],
        is_deleted: false
      }

      out = ConversationRendering.render_last_message(msg)
      assert out["content"] == "hello"
      assert out["messageType"] == "text"
      assert out["isDeleted"] == false
    end
  end

  describe "safe_binary_content/1" do
    test "nil → nil" do
      assert ConversationRendering.safe_binary_content(nil) == nil
    end

    test "valid UTF-8 binary → same binary" do
      assert ConversationRendering.safe_binary_content("hello") == "hello"
      assert ConversationRendering.safe_binary_content("héllô 🌍") == "héllô 🌍"
    end

    test "non-UTF-8 binary → Base64-encoded" do
      raw = <<255, 254, 253>>
      out = ConversationRendering.safe_binary_content(raw)
      assert is_binary(out)
      # Should be a valid base64 representation (or at least string-safe)
      assert out == Base.encode64(raw)
    end

    test "non-binary → to_string fallback" do
      assert ConversationRendering.safe_binary_content(42) == "42"
      assert ConversationRendering.safe_binary_content(:atom) == "atom"
    end
  end

  describe "render_member/1" do
    test "exposes role and is_active" do
      member = %{
        user_id: Ecto.UUID.generate(),
        settings: %{"role" => "admin"},
        joined_at: ~U[2026-04-01 00:00:00Z],
        is_active: true
      }

      out = ConversationRendering.render_member(member)
      assert out["userId"] == member.user_id
      assert out["role"] == "admin"
      assert out["isActive"] == true
    end

    test "defaults role to 'member' when settings is missing" do
      member = %{
        user_id: Ecto.UUID.generate(),
        settings: nil,
        joined_at: ~U[2026-04-01 00:00:00Z],
        is_active: true
      }

      out = ConversationRendering.render_member(member)
      assert out["role"] == "member"
    end

    test "defaults role to 'member' when settings is empty" do
      member = %{
        user_id: Ecto.UUID.generate(),
        settings: %{},
        joined_at: ~U[2026-04-01 00:00:00Z],
        is_active: false
      }

      out = ConversationRendering.render_member(member)
      assert out["role"] == "member"
      assert out["isActive"] == false
    end
  end

  describe "filter_by_type/2" do
    test "nil → returns input as-is" do
      conv1 = build_conv(type: "direct")
      conv2 = build_conv(type: "group")
      assert ConversationRendering.filter_by_type([conv1, conv2], nil) == [conv1, conv2]
    end

    test "filters by type 'direct'" do
      conv1 = build_conv(type: "direct")
      conv2 = build_conv(type: "group")
      assert ConversationRendering.filter_by_type([conv1, conv2], "direct") == [conv1]
    end

    test "filters by type 'group'" do
      conv1 = build_conv(type: "direct")
      conv2 = build_conv(type: "group")
      assert ConversationRendering.filter_by_type([conv1, conv2], "group") == [conv2]
    end
  end

  describe "render_conversation_with_members/3" do
    test "embeds members, count, and per-user flags when member_info is set" do
      members = [
        %{
          user_id: Ecto.UUID.generate(),
          settings: %{"role" => "admin"},
          joined_at: ~U[2026-04-01 00:00:00Z],
          is_active: true
        },
        %{
          user_id: Ecto.UUID.generate(),
          settings: %{"role" => "member"},
          joined_at: ~U[2026-04-02 00:00:00Z],
          is_active: true
        }
      ]

      conv = Map.put(build_conv(type: "group"), :members, members)
      member_info = %{settings: %{"is_muted" => true}}

      out = ConversationRendering.render_conversation_with_members(conv, member_info, nil)

      assert length(out["members"]) == 2
      assert out["memberCount"] == 2
      assert length(out["memberUserIds"]) == 2
      assert out["isMuted"] == true
    end

    test "without member_info, omits per-user flags overrides" do
      members = []
      conv = Map.put(build_conv(type: "group"), :members, members)

      out = ConversationRendering.render_conversation_with_members(conv, nil, nil)

      assert out["memberCount"] == 0
      # base render_conversation already sets isMuted=false default
      assert out["isMuted"] == false
    end
  end

  describe "render_conversations/2 (integration)" do
    test "maps each conversation through render_conversation/2" do
      conv1 = build_conv(type: "direct")
      conv2 = build_conv(type: "group")
      out = ConversationRendering.render_conversations([conv1, conv2], nil)
      assert length(out) == 2
      assert Enum.all?(out, &is_map/1)
    end
  end

  describe "render_conversation/2 — direct conversation memberUserIds via DB" do
    test "appends memberUserIds when conversation type is 'direct'" do
      {:ok, real_conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{"test" => true},
          is_active: true
        })

      u1 = Ecto.UUID.generate()
      u2 = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(real_conv.id, u1)
      {:ok, _} = Conversations.add_conversation_member(real_conv.id, u2)

      out = ConversationRendering.render_conversation(real_conv, nil)
      assert out["memberUserIds"] != nil
      assert length(out["memberUserIds"]) == 2
    end
  end
end
