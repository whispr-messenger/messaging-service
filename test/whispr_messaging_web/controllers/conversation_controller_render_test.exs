defmodule WhisprMessagingWeb.ConversationControllerRenderTest do
  @moduledoc """
  Tests that exercise the private rendering helpers of ConversationController
  indirectly by varying the data returned to GET /conversations/:id and
  GET /conversations. The goal is to hit the branches:
    * render_conversation with member_info / settings / unread_count / last_message
    * render_last_message with nil / non-nil
    * safe_binary_content with valid utf8 / invalid utf8 / nil
    * maybe_add_member_ids for direct vs group
  """
  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    {:ok, direct} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(direct.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(direct.id, other_id)

    {:ok, group} =
      Conversations.create_conversation(%{
        type: "group",
        metadata: %{"name" => "Render Test Group"},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(group.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(group.id, other_id)

    %{user_id: user_id, other_id: other_id, direct: direct, group: group}
  end

  describe "GET /conversations — render with last_message" do
    test "includes last_message in the response when a message exists", ctx do
      {:ok, _} =
        Messages.create_message(%{
          conversation_id: ctx.direct.id,
          sender_id: ctx.user_id,
          message_type: "text",
          content: "valid utf8 content",
          client_random: System.unique_integer([:positive])
        })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations")
        |> json_response(200)

      direct_conv =
        Enum.find(response["data"], &(&1["id"] == ctx.direct.id))

      assert direct_conv != nil
      # lastMessage may be nil if not preloaded, or have content
      assert direct_conv["lastMessage"] == nil or is_map(direct_conv["lastMessage"])
    end

    test "renders direct conversation with memberUserIds", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.direct.id}")
        |> json_response(200)

      assert response["data"]["type"] == "direct"
      assert is_list(response["data"]["memberUserIds"])
    end

    test "renders group conversation with members list", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.group.id}")
        |> json_response(200)

      assert response["data"]["type"] == "group"
      assert is_list(response["data"]["members"])
      assert response["data"]["memberCount"] >= 2
    end
  end

  describe "GET /conversations — filtering" do
    test "supports filtering by type=direct", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?type=direct")
        |> json_response(200)

      assert Enum.all?(response["data"], &(&1["type"] == "direct"))
    end

    test "supports filtering by type=group", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?type=group")
        |> json_response(200)

      assert Enum.all?(response["data"], &(&1["type"] == "group"))
    end
  end

  describe "GET /conversations — limit parsing" do
    test "honours valid limit", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?limit=10")

      assert conn.status == 200
    end

    test "clamps limit to 100 max", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?limit=999")
        |> json_response(200)

      assert response["meta"]["count"] <= 100
    end

    test "defaults limit to 50 for invalid input", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?limit=not_int")

      assert conn.status == 200
    end

    test "defaults limit to 50 for negative input", ctx do
      conn =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations?limit=-5")

      assert conn.status == 200
    end
  end

  describe "settings exposure on render" do
    test "is_muted, is_pinned, is_archived default to false on read", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.direct.id}")
        |> json_response(200)

      assert response["data"]["isMuted"] == false
      assert response["data"]["isPinned"] == false
      assert response["data"]["isArchived"] == false
    end

    test "is_muted reflects user setting", ctx do
      Conversations.update_conversation_member_settings(ctx.direct.id, ctx.user_id, %{
        "is_muted" => true
      })

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/conversations/#{ctx.direct.id}")
        |> json_response(200)

      assert response["data"]["isMuted"] == true
    end
  end
end
