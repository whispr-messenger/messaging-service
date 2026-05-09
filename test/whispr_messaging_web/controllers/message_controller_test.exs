defmodule WhisprMessagingWeb.MessageControllerTest do
  use WhisprMessagingWeb.ConnCase, async: true
  use WhisprMessagingWeb, :verified_routes

  alias WhisprMessaging.{Conversations, Messages}

  setup do
    # Create test users
    user1_id = Ecto.UUID.generate()
    user2_id = Ecto.UUID.generate()

    # Create test conversation
    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    # Add members
    {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
    {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

    %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    }
  end

  describe "GET /messaging/api/v1/conversations/:id/messages" do
    test "lists messages for a conversation", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create test messages
      for i <- 1..3 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "message_#{i}",
          client_random: i
        })
      end

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(200)

      assert response["data"] != nil
      assert Enum.count(response["data"]) == 3
    end

    test "returns empty list when no messages exist", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(200)

      assert response["data"] == []
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{fake_id}/messages")
        |> json_response(404)

      assert response["error"] in ["Conversation not found", "Resource not found"]
    end

    test "returns 403 when user is not a member", %{conversation: conversation} do
      unauthorized_user = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(unauthorized_user)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}/messages")
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "supports pagination with limit parameter", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # Create 10 messages
      for i <- 1..10 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "message_#{i}",
          client_random: i + 1000
        })
      end

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        get(conn, ~p"/messaging/api/v1/conversations/#{conversation.id}/messages?limit=5")
        |> json_response(200)

      assert Enum.count(response["data"]) <= 5
    end
  end

  describe "POST /messaging/api/v1/conversations/:id/messages" do
    test "creates a new message and broadcasts new_message event (WHISPR-915)", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # Abonnement aux topics conversation et user pour vérifier la diffusion
      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conversation.id}"
      )

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user2_id}")

      message_attrs = %{
        "content" => "encrypted_content",
        "message_type" => "text",
        "client_random" => 12_345,
        "metadata" => %{"test" => true},
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(201)

      assert response["data"]["id"] != nil
      assert response["data"]["content"] == "encrypted_content"
      assert response["data"]["messageType"] == "text"
      assert response["data"]["senderId"] == user1_id
      assert response["data"]["conversationId"] == conversation.id
      assert response["data"]["deliveryStatus"] in ["sent", "pending"]

      # La diffusion doit arriver sur le topic conversation (pour ChatScreen ouvert)
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "new_message",
                       payload: %{message: broadcast_msg}
                     },
                     1_000

      assert broadcast_msg["id"] == response["data"]["id"]
      assert broadcast_msg["clientRandom"] == 12_345

      # Et sur le topic user:{memberId} pour chaque membre hors expéditeur
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> _,
                       event: "new_message",
                       payload: %{message: _}
                     },
                     1_000
    end

    test "returns 422 with invalid attributes", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      invalid_attrs = %{
        "content" => "",
        "message_type" => "invalid_type",
        "client_random" => nil,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          invalid_attrs
        )
        |> json_response(422)

      assert response["error"] == "Validation failed"
      assert response["details"] != nil
    end

    test "returns 404 for non-existent conversation", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 12_345,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{fake_id}/messages",
          message_attrs
        )
        |> json_response(404)

      assert response["error"] in ["Conversation not found", "Resource not found"]
    end

    test "returns 403 when user is not a member", %{conversation: conversation} do
      unauthorized_user = Ecto.UUID.generate()

      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 12_345,
        "sender_id" => unauthorized_user
      }

      conn =
        build_conn()
        |> authenticated_conn(unauthorized_user)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(403)

      assert response["error"] == "Unauthorized"
    end

    test "returns 422 when signature verification fails", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)

      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 77_777,
        "sender_id" => user1_id,
        "signature" => Base.encode64(:crypto.strong_rand_bytes(64)),
        "sender_public_key" => Base.encode64(pub)
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(422)

      assert response["error"] == "Invalid message signature"
    end

    test "creates a message without signature (backward compat)", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      message_attrs = %{
        "content" => "no_sig_content",
        "message_type" => "text",
        "client_random" => 88_888,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(201)

      assert response["data"]["id"] != nil
    end

    test "prevents duplicate client_random", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      message_attrs = %{
        "content" => "test",
        "message_type" => "text",
        "client_random" => 99_999,
        "sender_id" => user1_id
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      # First message should succeed
      post(
        conn,
        ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
        message_attrs
      )
      |> json_response(201)

      # Second message with same client_random should fail
      response =
        post(
          conn,
          ~p"/messaging/api/v1/conversations/#{conversation.id}/messages",
          message_attrs
        )
        |> json_response(422)

      assert response["error"] == "Validation failed"
      assert response["details"] != nil
    end
  end

  describe "PUT /messaging/api/v1/messages/:id" do
    setup %{conversation: conversation, user1_id: user1_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 54_321
        })

      %{message: message}
    end

    test "updates a message and broadcasts message_edited (WHISPR-915)", %{
      message: message,
      conversation: conversation,
      user1_id: user1_id
    } do
      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conversation.id}"
      )

      update_attrs = %{
        "content" => "updated_content",
        "metadata" => %{"edited" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          update_attrs
        )
        |> json_response(200)

      assert response["data"]["content"] == "updated_content"
      assert response["data"]["metadata"]["edited"] == true
      assert response["data"]["editedAt"] != nil

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "message_edited",
                       payload: %{message: broadcast_msg}
                     },
                     1_000

      assert broadcast_msg["id"] == message.id
    end

    test "edit fanout sur user:* de chaque membre (WHISPR-1307)", %{
      message: message,
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user1_id}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user2_id}")

      update_attrs = %{
        "content" => "fanout_content",
        "metadata" => %{"edited" => true}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      _response =
        put(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          update_attrs
        )
        |> json_response(200)

      # WHISPR-1315 : on exclut l editeur (sender du message d origine) du
      # fanout user:* sinon il recoit l event 2x (une fois sur conversation:*,
      # une fois sur son propre user:*). Seul user2 doit recevoir sur user:*.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> recipient_topic,
                       event: "message_edited",
                       payload: %{message: payload_recipient}
                     },
                     1_000

      assert recipient_topic == user2_id
      assert payload_recipient["id"] == message.id
      assert payload_recipient["conversationId"] == conversation.id

      # Le sender ne doit PAS recevoir d event sur user:* (filtre WHISPR-1315).
      sender_topic = "user:#{user1_id}"

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^sender_topic,
                       event: "message_edited"
                     },
                     200
    end

    test "returns 404 for non-existent message", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      update_attrs = %{
        "content" => "new_content",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/messaging/api/v1/messages/#{fake_id}",
          update_attrs
        )
        |> json_response(404)

      # The actual error message from fallback controller is "Resource not found"
      # But we can accept either standard message
      assert response["error"] in ["Message not found", "Resource not found"]
    end

    test "returns 403 when trying to edit another user's message", %{
      message: message,
      user2_id: user2_id
    } do
      update_attrs = %{
        "content" => "hacked_content",
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          update_attrs
        )
        # FallbackController might be rendering 403 correctly now
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "returns 422 with invalid content", %{message: message, user1_id: user1_id} do
      # Update with invalid attributes
      update_attrs = %{
        "content" => nil,
        "metadata" => %{}
      }

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        put(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          update_attrs
        )
        |> json_response(422)

      assert response["errors"] != nil
    end
  end

  describe "DELETE /messaging/api/v1/messages/:id" do
    setup %{conversation: conversation, user1_id: user1_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "content_to_delete",
          client_random: 77_777
        })

      %{message: message}
    end

    test "deletes a message and broadcasts message_deleted (WHISPR-915)", %{
      message: message,
      conversation: conversation,
      user1_id: user1_id
    } do
      Phoenix.PubSub.subscribe(
        WhisprMessaging.PubSub,
        "conversation:#{conversation.id}"
      )

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: true
        )
        |> json_response(200)

      assert response["data"]["isDeleted"] == true
      assert response["data"]["deleteForEveryone"] == true

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "message_deleted",
                       payload: payload
                     },
                     1_000

      assert payload["messageId"] == message.id
      assert payload["deleteForEveryone"] == true
    end

    test "delete_for_everyone fanout sur user:* de chaque membre (WHISPR-1293)", %{
      message: message,
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # Subscribe sur les deux topics user:* pour verifier le fanout
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user1_id}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user2_id}")

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      _response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: true
        )
        |> json_response(200)

      # WHISPR-1315 : le sender est exclu du fanout user:* (il recoit deja
      # via conversation:*). Seul user2 doit recevoir sur user:*.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> recipient_topic,
                       event: "message_deleted",
                       payload: payload_recipient
                     },
                     1_000

      assert recipient_topic == user2_id
      assert payload_recipient["messageId"] == message.id
      assert payload_recipient["conversationId"] == conversation.id
      assert payload_recipient["deleteForEveryone"] == true

      # Le sender ne doit PAS recevoir d event sur user:* (filtre WHISPR-1315).
      sender_topic = "user:#{user1_id}"

      refute_receive %Phoenix.Socket.Broadcast{
                       topic: ^sender_topic,
                       event: "message_deleted"
                     },
                     200
    end

    test "soft delete (pour moi) ne diffuse PAS sur user:* (WHISPR-1293)", %{
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user1_id}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user2_id}")

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      _response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(200)

      refute_receive %Phoenix.Socket.Broadcast{event: "message_deleted"}, 300
    end

    test "soft delete (pour moi) ne diffuse PAS message_deleted (WHISPR-915)", %{
      message: message,
      conversation: conversation,
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

      _response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(200)

      refute_receive %Phoenix.Socket.Broadcast{event: "message_deleted"}, 300
    end

    test "returns 404 for non-existent message", %{user1_id: user1_id} do
      fake_id = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{fake_id}",
          delete_for_everyone: false
        )
        |> json_response(404)

      assert response["error"] in ["Message not found", "Resource not found"]
    end

    test "allows another user to delete for me (per-user deletion)", %{
      message: message,
      user2_id: user2_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(200)

      assert response["data"]["isDeleted"] == true
      assert response["data"]["deleteForEveryone"] == false
    end

    test "returns 403 when non-sender tries to delete for everyone", %{
      message: message,
      user2_id: user2_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: true
        )
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end

    test "soft deletes message without delete_for_everyone", %{
      message: message,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        delete(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}",
          delete_for_everyone: false
        )
        |> json_response(200)

      assert response["data"]["isDeleted"] == true
      assert response["data"]["deleteForEveryone"] == false
    end
  end

  describe "POST /messaging/api/v1/messages/:id/forward" do
    setup %{conversation: conversation, user1_id: user1_id, user2_id: user2_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "to-forward",
          client_random: 424_242
        })

      {:ok, target} =
        Conversations.create_conversation(%{type: "direct", is_active: true})

      {:ok, _} = Conversations.add_conversation_member(target.id, user1_id)
      {:ok, _} = Conversations.add_conversation_member(target.id, user2_id)

      %{source_message: message, target_conversation: target}
    end

    test "forwards a message to a target conversation", %{
      source_message: message,
      target_conversation: target,
      user1_id: user1_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user1_id)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}/forward",
          conversation_ids: [target.id]
        )
        |> json_response(201)

      assert [forwarded] = response["data"]
      assert forwarded["conversationId"] == target.id
      assert forwarded["forwardedFromId"] == message.id
    end

    test "returns 403 when user is not a member of the source conversation", %{
      source_message: message,
      target_conversation: target
    } do
      outsider = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(outsider)
        |> json_conn()

      response =
        post(
          conn,
          ~p"/messaging/api/v1/messages/#{message.id}/forward",
          conversation_ids: [target.id]
        )
        |> json_response(403)

      assert response["error"] == "Forbidden"
    end
  end

  # WHISPR-1059
  describe "PATCH /messaging/api/v1/messages/:id/receipt" do
    setup %{conversation: conversation, user1_id: user1_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "receipt target",
          client_random: 555_555
        })

      %{message: message}
    end

    test "marks the message as delivered for the caller", %{
      message: message,
      user2_id: user2_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        patch(conn, ~p"/messaging/api/v1/messages/#{message.id}/receipt", status: "delivered")
        |> json_response(200)

      assert response["data"]["message_id"] == message.id
      assert response["data"]["user_id"] == user2_id
      assert response["data"]["delivered_at"] != nil
      assert response["data"]["read_at"] == nil
    end

    test "marks the message as read AND backfills delivered_at on the same row", %{
      message: message,
      user2_id: user2_id
    } do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        patch(conn, ~p"/messaging/api/v1/messages/#{message.id}/receipt", status: "read")
        |> json_response(200)

      assert response["data"]["message_id"] == message.id
      assert response["data"]["user_id"] == user2_id
      assert response["data"]["delivered_at"] != nil
      assert response["data"]["read_at"] != nil
    end

    test "returns 400 when status is missing or invalid", %{message: message, user2_id: user2_id} do
      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      assert %{"errors" => %{"status" => _}} =
               patch(conn, ~p"/messaging/api/v1/messages/#{message.id}/receipt",
                 status: "unknown"
               )
               |> json_response(400)

      assert %{"errors" => %{"status" => _}} =
               patch(conn, ~p"/messaging/api/v1/messages/#{message.id}/receipt", %{})
               |> json_response(400)
    end

    test "returns 404 for a non-existent message", %{user2_id: user2_id} do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      assert %{"errors" => _} =
               patch(conn, ~p"/messaging/api/v1/messages/#{missing}/receipt", status: "delivered")
               |> json_response(404)
    end
  end

  # WHISPR-1304: POST /messaging/api/v1/messages/:id/unread
  describe "POST /messaging/api/v1/messages/:id/unread (WHISPR-1304)" do
    setup %{conversation: conversation, user1_id: user1_id, user2_id: user2_id} do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "to_unmark",
          client_random: 77_777
        })

      # user2 a deja lu le message
      {:ok, _} = Messages.mark_message_read(message.id, user2_id)

      %{message: message, _user2: user2_id}
    end

    test "renvoie 200 + broadcast message_unread", %{
      conversation: conversation,
      message: message,
      user2_id: user2_id
    } do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{conversation.id}")

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/messages/#{message.id}/unread")
        |> json_response(200)

      assert response["data"]["status"] == "unread"
      assert response["data"]["messageId"] == message.id
      assert response["data"]["conversationId"] == conversation.id

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "conversation:" <> _,
                       event: "message_unread"
                     },
                     1_000
    end

    test "renvoie 404 quand le message n'existe pas", %{user2_id: user2_id} do
      missing = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      assert %{"errors" => _} =
               post(conn, ~p"/messaging/api/v1/messages/#{missing}/unread")
               |> json_response(404)
    end

    test "renvoie 403 quand le caller n'est pas membre de la conversation", %{message: message} do
      stranger = Ecto.UUID.generate()

      conn =
        build_conn()
        |> authenticated_conn(stranger)
        |> json_conn()

      assert %{"errors" => _} =
               post(conn, ~p"/messaging/api/v1/messages/#{message.id}/unread")
               |> json_response(403)
    end

    test "skip le broadcast quand reader.read_receipts=false", %{
      conversation: conversation,
      message: message,
      user2_id: user2_id
    } do
      Process.put(:mock_user_service_client, %{
        get_privacy_settings: fn ^user2_id ->
          {:ok,
           %{
             read_receipts: false,
             last_seen_privacy: nil,
             online_status: nil
           }}
        end
      })

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{conversation.id}")

      conn =
        build_conn()
        |> authenticated_conn(user2_id)
        |> json_conn()

      response =
        post(conn, ~p"/messaging/api/v1/messages/#{message.id}/unread")
        |> json_response(200)

      assert response["data"]["status"] == "unread"

      refute_receive %Phoenix.Socket.Broadcast{event: "message_unread"}, 200
    end
  end
end
