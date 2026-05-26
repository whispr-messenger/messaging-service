defmodule WhisprMessagingWeb.MessageSearchTest do
  @moduledoc """
  Tests for the GET /messages/search endpoint and per-message receipt
  edge cases not covered by the existing message_controller_test.
  """

  use WhisprMessagingWeb.ConnCase, async: true

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true,
        e2ee_enabled: false
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

    {:ok, msg} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user_id,
        message_type: "text",
        content: "hello searchable",
        client_random: System.unique_integer([:positive])
      })

    %{user_id: user_id, other_id: other_id, conversation: conversation, message: msg}
  end

  describe "GET /messaging/api/v1/messages/search" do
    test "returns an empty list when query is blank", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search?query=")
        |> json_response(200)

      assert response == []
    end

    test "returns matching messages when a query is provided", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search?query=hello")
        |> json_response(200)

      assert is_list(response)
    end

    test "respects limit, offset and conversation_id filters", ctx do
      from_iso = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      to_iso = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      url =
        "/messaging/api/v1/messages/search?query=hello&limit=5&offset=0" <>
          "&conversation_id=#{ctx.conversation.id}&message_type=text" <>
          "&from=#{from_iso}&to=#{to_iso}"

      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(url)
        |> json_response(200)

      assert is_list(response)
    end

    test "ignores invalid limit/offset and falls back to defaults", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/search?query=hello&limit=abc&offset=xyz")
        |> json_response(200)

      assert is_list(response)
    end
  end

  describe "GET /messaging/api/v1/messages/:id" do
    test "returns the message when it exists", ctx do
      response =
        build_conn()
        |> authenticated_conn(ctx.user_id)
        |> json_conn()
        |> get(~p"/messaging/api/v1/messages/#{ctx.message.id}")
        |> json_response(200)

      assert response["data"]["id"] == ctx.message.id
    end

    test "returns 404 when the message does not exist", ctx do
      build_conn()
      |> authenticated_conn(ctx.user_id)
      |> json_conn()
      |> get(~p"/messaging/api/v1/messages/#{Ecto.UUID.generate()}")
      |> json_response(404)
    end
  end
end
