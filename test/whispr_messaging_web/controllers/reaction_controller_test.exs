defmodule WhisprMessagingWeb.ReactionControllerTest do
  @moduledoc """
  Tests de la diffusion WebSocket depuis `ReactionController` (WHISPR-915).
  """
  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _m1} = Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _m2} = Conversations.add_conversation_member(conversation.id, user2_id)

    {:ok, message} =
      Messages.create_message(%{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "message_to_react_to",
        client_random: 42_424
      })

    %{
      conversation: conversation,
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    }
  end

  describe "POST /messaging/api/v1/messages/:id/reactions" do
    test "ajoute une réaction et diffuse reaction_added", %{
      conversation: conversation,
      message: message,
      user2_id: user2_id
    } do
      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conversation.id}"
      )

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}/reactions",
          %{"reaction" => "👍"}
        )
        |> json_response(201)

      assert response["data"]["reaction"] == "👍"

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "reaction_added",
                       payload: payload
                     },
                     1_000

      assert payload["messageId"] == message.id
      assert payload["userId"] == user2_id
      assert payload["reaction"] == "👍"
    end
  end

  describe "DELETE /messaging/api/v1/messages/:id/reactions/:reaction" do
    test "retire une réaction et diffuse reaction_removed", %{
      conversation: conversation,
      message: message,
      user2_id: user2_id
    } do
      # Crée d'abord la réaction
      {:ok, _} = Messages.add_reaction(message.id, user2_id, "👍")

      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conversation.id}"
      )

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}/reactions/#{"👍"}"
        )
        |> json_response(200)

      assert response["data"]["deleted"] == true

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "reaction_removed",
                       payload: payload
                     },
                     1_000

      assert payload["messageId"] == message.id
      assert payload["userId"] == user2_id
      assert payload["reaction"] == "👍"
    end
  end
end
