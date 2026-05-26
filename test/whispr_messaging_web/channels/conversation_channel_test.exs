defmodule WhisprMessagingWeb.ConversationChannelTest do
  use WhisprMessagingWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.BlockCache
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Repo
  alias WhisprMessagingWeb.ConversationChannel
  alias WhisprMessagingWeb.UserSocket

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    user_id = Ecto.UUID.generate()
    other_user_id = Ecto.UUID.generate()

    # Create test conversation
    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true,
        e2ee_enabled: false
      })

    # Add both users as members
    {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _member2} = Conversations.add_conversation_member(conversation.id, other_user_id)

    # Create socket with user authentication
    socket = socket(UserSocket, "user_socket:#{user_id}", %{user_id: user_id})

    %{
      socket: socket,
      conversation: conversation,
      user_id: user_id,
      other_user_id: other_user_id
    }
  end

  describe "join conversation channel" do
    test "joins successfully when user is a member", %{
      socket: socket,
      conversation: conversation
    } do
      assert {:ok, reply, _socket} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )

      assert reply.conversation.id == conversation.id
    end

    test "fails to join when user is not a member", %{socket: socket} do
      # Create conversation without adding the user as member
      {:ok, other_conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true
        })

      assert {:error, %{reason: "not_authorized"}} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{other_conversation.id}"
               )
    end

    test "fails to join non-existent conversation", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      assert {:error, %{reason: "conversation_not_found"}} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{fake_id}"
               )
    end
  end

  describe "new_message" do
    setup %{socket: socket, conversation: conversation} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      %{socket: socket}
    end

    test "creates and broadcasts a new message", %{
      socket: socket,
      conversation: conversation,
      user_id: user_id
    } do
      message_attrs = %{
        "content" => "encrypted_test_content",
        "message_type" => "text",
        "client_random" => 12_345,
        "metadata" => %{"test" => true}
      }

      ref = push(socket, "new_message", message_attrs)

      assert_reply ref, :ok, %{message: reply_message}
      assert reply_message["content"] == "encrypted_test_content"
      assert reply_message["messageType"] == "text"
      assert reply_message["senderId"] == user_id
      assert reply_message["conversationId"] == conversation.id
      assert reply_message["deliveryStatus"] in ["sent", "pending"]

      # Should broadcast to all channel subscribers
      assert_broadcast "new_message", %{message: broadcast_message}
      assert broadcast_message["id"] == reply_message["id"]
    end

    test "fails with invalid message data", %{socket: socket} do
      invalid_attrs = %{
        "content" => "",
        "message_type" => "invalid_type",
        "client_random" => nil
      }

      ref = push(socket, "new_message", invalid_attrs)
      assert_reply ref, :error, %{errors: _errors}
    end

    test "handles duplicate client_random idempotently", %{
      socket: socket
    } do
      message_attrs = %{
        "content" => "test_content",
        "message_type" => "text",
        "client_random" => 99_999,
        "metadata" => %{}
      }

      # First message should succeed
      ref1 = push(socket, "new_message", message_attrs)
      assert_reply ref1, :ok, %{message: message1}

      # Second message with same client_random should succeed and return original message
      ref2 = push(socket, "new_message", message_attrs)
      assert_reply ref2, :ok, %{message: message2}

      assert message1["id"] == message2["id"]
    end
  end

  describe "edit_message" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to edit
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "original_content",
          client_random: 54_321
        })

      %{socket: socket, message: message}
    end

    test "edits own message successfully", %{
      socket: socket,
      message: message
    } do
      edit_attrs = %{
        "message_id" => message.id,
        "content" => "edited_content",
        "metadata" => %{"edited" => true}
      }

      ref = push(socket, "edit_message", edit_attrs)

      assert_reply ref, :ok, %{message: edited_message}
      assert edited_message["content"] == "edited_content"
      assert edited_message["metadata"]["edited"] == true
      assert edited_message["editedAt"] != nil

      # Should broadcast edit to all subscribers
      assert_broadcast "message_edited", %{message: broadcast_message}
      assert broadcast_message["id"] == message.id
    end

    test "fails to edit non-existent message", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      edit_attrs = %{
        "message_id" => fake_id,
        "content" => "new_content",
        "metadata" => %{}
      }

      ref = push(socket, "edit_message", edit_attrs)
      assert_reply ref, :error, %{reason: "not_found"}
    end

    test "fails to edit other user's message", %{
      socket: socket,
      conversation: conversation,
      other_user_id: other_user_id
    } do
      # Create message from other user
      {:ok, other_message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: other_user_id,
          message_type: "text",
          content: "other_content",
          client_random: 11_111
        })

      edit_attrs = %{
        "message_id" => other_message.id,
        "content" => "hacked_content",
        "metadata" => %{}
      }

      ref = push(socket, "edit_message", edit_attrs)
      assert_reply ref, :error, %{reason: "forbidden"}
    end

    test "edit fanout sur user:* de chaque membre (WHISPR-1307)", %{
      socket: socket,
      message: message,
      conversation: conversation,
      user_id: user_id,
      other_user_id: other_user_id
    } do
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{user_id}")
      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "user:#{other_user_id}")

      edit_attrs = %{
        "message_id" => message.id,
        "content" => "edited_fanout",
        "metadata" => %{"edited" => true}
      }

      ref = push(socket, "edit_message", edit_attrs)
      assert_reply ref, :ok, %{message: _edited_message}

      # Sender doit recevoir l event sur son canal user:* meme si la ChatScreen
      # ne diffuse que sur "conversation:*".
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> sender_topic,
                       event: "message_edited",
                       payload: payload_sender
                     },
                     1_000

      assert sender_topic == user_id
      assert payload_sender.message["id"] == message.id
      assert payload_sender.message["conversationId"] == conversation.id

      # L autre membre doit aussi recevoir l event meme sans avoir la ChatScreen ouverte.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> recipient_topic,
                       event: "message_edited",
                       payload: payload_recipient
                     },
                     1_000

      assert recipient_topic == other_user_id
      assert payload_recipient.message["id"] == message.id
    end
  end

  describe "delete_message" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to delete
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "content_to_delete",
          client_random: 77_777
        })

      %{socket: socket, message: message}
    end

    test "deletes own message successfully", %{
      socket: socket,
      message: message
    } do
      delete_attrs = %{
        "message_id" => message.id,
        "delete_for_everyone" => true
      }

      ref = push(socket, "delete_message", delete_attrs)

      assert_reply ref, :ok, %{message: deleted_message}
      assert deleted_message["isDeleted"] == true
      assert deleted_message["deleteForEveryone"] == true

      # Should broadcast deletion to all subscribers
      assert_broadcast "message_deleted", %{
        "messageId" => broadcast_message_id,
        "deleteForEveryone" => true
      }

      assert broadcast_message_id == message.id
    end

    test "fails to delete non-existent message", %{socket: socket} do
      fake_id = Ecto.UUID.generate()

      delete_attrs = %{
        "message_id" => fake_id,
        "delete_for_everyone" => false
      }

      ref = push(socket, "delete_message", delete_attrs)
      assert_reply ref, :error, %{reason: "message_not_found"}
    end
  end

  describe "message delivery and read receipts" do
    setup %{socket: socket, conversation: conversation, user_id: _user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message from other user
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: Ecto.UUID.generate(),
          message_type: "text",
          content: "test_content",
          client_random: 33_333
        })

      %{socket: socket, message: message}
    end

    test "marks message as delivered", %{
      socket: socket,
      message: message
    } do
      ref = push(socket, "message_delivered", %{"message_id" => message.id})
      assert_reply ref, :ok, %{status: "delivered"}
    end

    test "marks message as read", %{
      socket: socket,
      message: message
    } do
      ref = push(socket, "message_read", %{"message_id" => message.id})
      assert_reply ref, :ok, %{status: "read"}
    end
  end

  describe "typing indicators" do
    setup %{socket: socket, conversation: conversation} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      %{socket: socket}
    end

    test "broadcasts typing start", %{
      socket: socket,
      user_id: user_id,
      conversation: conversation
    } do
      push(socket, "typing_start", %{})

      assert_broadcast "user_typing", %{
        "userId" => broadcast_user_id,
        "conversationId" => broadcast_conversation_id,
        "typing" => true
      }

      assert broadcast_user_id == user_id
      assert broadcast_conversation_id == conversation.id
    end

    test "broadcasts typing stop", %{socket: socket, user_id: user_id, conversation: conversation} do
      push(socket, "typing_stop", %{})

      assert_broadcast "user_typing", %{
        "userId" => broadcast_user_id,
        "conversationId" => broadcast_conversation_id,
        "typing" => false
      }

      assert broadcast_user_id == user_id
      assert broadcast_conversation_id == conversation.id
    end
  end

  describe "reactions" do
    setup %{socket: socket, conversation: conversation, user_id: user_id} do
      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Create a message to react to
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "message_to_react",
          client_random: 55_555
        })

      %{socket: socket, message: message}
    end

    test "adds reaction successfully", %{
      socket: socket,
      message: message,
      user_id: user_id
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👍"
      }

      ref = push(socket, "add_reaction", reaction_attrs)

      assert_reply ref, :ok, %{reaction: reply_reaction}
      assert reply_reaction["messageId"] == message.id
      assert reply_reaction["userId"] == user_id
      assert reply_reaction["reaction"] == "👍"

      # Should broadcast reaction to all subscribers
      assert_broadcast "reaction_added", %{
        "messageId" => broadcast_message_id,
        "userId" => broadcast_user_id,
        "reaction" => "👍"
      }

      assert broadcast_message_id == message.id
      assert broadcast_user_id == user_id
    end

    test "removes reaction successfully", %{
      socket: socket,
      message: message
    } do
      # First add a reaction
      Messages.add_reaction(message.id, socket.assigns.user_id, "👍")

      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👍"
      }

      ref = push(socket, "remove_reaction", reaction_attrs)

      assert_reply ref, :ok, %{status: "removed"}

      # Should broadcast removal to all subscribers
      assert_broadcast "reaction_removed", %{
        "messageId" => broadcast_message_id,
        "userId" => broadcast_user_id,
        "reaction" => "👍"
      }

      assert broadcast_message_id == message.id
      assert broadcast_user_id == socket.assigns.user_id
    end

    test "fails to remove non-existent reaction", %{
      socket: socket,
      message: message
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "👎"
      }

      ref = push(socket, "remove_reaction", reaction_attrs)
      assert_reply ref, :error, %{reason: "reaction_not_found"}
    end

    test "prevents duplicate reactions", %{
      socket: socket,
      message: message
    } do
      reaction_attrs = %{
        "message_id" => message.id,
        "reaction" => "❤️"
      }

      # First reaction should succeed
      ref1 = push(socket, "add_reaction", reaction_attrs)
      assert_reply ref1, :ok, %{reaction: _}

      # Duplicate reaction should fail
      ref2 = push(socket, "add_reaction", reaction_attrs)
      assert_reply ref2, :error, %{errors: _}
    end
  end

  describe "presence tracking" do
    test "tracks user presence on join", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Should receive presence state
      assert_push "presence_state", _presence_state
    end

    test "receives presence diffs", %{
      socket: socket,
      conversation: conversation
    } do
      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      # Presence diffs would be pushed when other users join/leave
      # This is tested indirectly through the presence system
    end
  end

  describe "block bypass in group chat (WHISPR-1364)" do
    setup do
      # Reset le cache ETS entre tests pour ne pas hereditrer un etat
      # d'une suite precedente.
      BlockCache.reset()

      on_exit(fn ->
        Application.delete_env(:whispr_messaging, :mock_user_service_client_overrides)
      end)

      :ok
    end

    test "skips new_message push when sender is blocked by recipient" do
      # On verifie le contrat handle_out : si la map de blocks contient
      # le sender pour le user assis derriere ce socket, l event est
      # skippe. Test focal sur le filtre, pas sur le pipeline complet.
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "test-group"},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(conversation.id, user_a)
      {:ok, _} = Conversations.add_conversation_member(conversation.id, user_b)

      Application.put_env(:whispr_messaging, :mock_user_service_client_overrides, %{
        check_user_blocked: fn
          ^user_a, ^user_b -> {:ok, true}
          ^user_b, ^user_a -> {:ok, true}
          _, _ -> {:ok, false}
        end
      })

      socket_a = socket(UserSocket, "user_socket:#{user_a}", %{user_id: user_a})

      {:ok, _, _channel_a_socket} =
        subscribe_and_join(socket_a, ConversationChannel, "conversation:#{conversation.id}")

      # Simule un broadcast de B sur le topic conversation. Avec
      # `intercept`, le payload arrive a `handle_out` du channel pid de
      # A et doit etre skippe par le filtre block.
      payload = %{
        message: %{
          "senderId" => user_b,
          "content" => "ignored",
          "messageType" => "text"
        }
      }

      WhisprMessagingWeb.Endpoint.broadcast(
        "conversation:#{conversation.id}",
        "new_message",
        payload
      )

      # Si le filtre marche, le push n'est jamais propage au transport
      # (test pid). 200ms de marge pour le traitement du handle_out.
      refute_push "new_message", _, 200
    end

    test "delivers new_message push when no block exists" do
      # Test miroir du precedent : sans block, le filtre passe through.
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "test-group"},
          is_active: true
        })

      {:ok, _} = Conversations.add_conversation_member(conversation.id, user_a)
      {:ok, _} = Conversations.add_conversation_member(conversation.id, user_b)

      Application.put_env(:whispr_messaging, :mock_user_service_client_overrides, %{
        check_user_blocked: fn _, _ -> {:ok, false} end
      })

      socket_a = socket(UserSocket, "user_socket:#{user_a}", %{user_id: user_a})

      {:ok, _, _channel_a} =
        subscribe_and_join(socket_a, ConversationChannel, "conversation:#{conversation.id}")

      payload = %{
        message: %{
          "senderId" => user_b,
          "content" => "delivered",
          "messageType" => "text"
        }
      }

      WhisprMessagingWeb.Endpoint.broadcast(
        "conversation:#{conversation.id}",
        "new_message",
        payload
      )

      assert_push "new_message", %{message: %{"senderId" => ^user_b}}
    end

    test "joins direct conversation when not blocked", %{
      socket: socket,
      conversation: conversation,
      user_id: _user_id,
      other_user_id: _other_user_id
    } do
      Application.put_env(:whispr_messaging, :mock_user_service_client_overrides, %{
        check_user_blocked: fn _, _ -> {:ok, false} end
      })

      assert {:ok, _, _socket} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )
    end

    test "blocks join on direct conversation when users have a block", %{
      socket: socket,
      conversation: conversation
    } do
      Application.put_env(:whispr_messaging, :mock_user_service_client_overrides, %{
        check_user_blocked: fn _, _ -> {:ok, true} end
      })

      assert {:error, %{reason: "blocked"}} =
               subscribe_and_join(
                 socket,
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )
    end

    test "block cache returns the same map within TTL", %{
      conversation: conversation,
      user_id: user_a,
      other_user_id: user_b
    } do
      # 1er appel calcule, le cache stocke. 2eme appel doit lire le cache
      # (on le verifie en stub-ant pour qu'il leve si re-appele).
      counter = :counters.new(1, [])

      Process.put(:mock_user_service_client, %{
        check_user_blocked: fn _, _ ->
          :counters.add(counter, 1, 1)
          {:ok, true}
        end
      })

      blocks1 =
        BlockCache.get_for_conversation(
          conversation.id,
          [user_a, user_b]
        )

      blocks2 =
        BlockCache.get_for_conversation(
          conversation.id,
          [user_a, user_b]
        )

      assert blocks1 == blocks2
      # Le 2eme appel ne doit pas avoir touche le mock (cache hit).
      # Une paire (a,b) + (b,a) = 2 appels au max sur le 1er run.
      first_run_calls = :counters.get(counter, 1)
      assert first_run_calls > 0
      assert first_run_calls <= 2
    end

    test "block cache invalidate forces a refetch", %{
      conversation: conversation,
      user_id: user_a,
      other_user_id: user_b
    } do
      counter = :counters.new(1, [])

      Process.put(:mock_user_service_client, %{
        check_user_blocked: fn _, _ ->
          :counters.add(counter, 1, 1)
          {:ok, false}
        end
      })

      _ =
        BlockCache.get_for_conversation(
          conversation.id,
          [user_a, user_b]
        )

      first_calls = :counters.get(counter, 1)
      assert first_calls > 0

      :ok = BlockCache.invalidate(conversation.id)

      _ =
        BlockCache.get_for_conversation(
          conversation.id,
          [user_a, user_b]
        )

      total_calls = :counters.get(counter, 1)
      assert total_calls > first_calls
    end
  end

  describe "typing timeout cleanup (WHISPR-1352)" do
    test "untracks typing presence on :stop_typing message", %{
      socket: socket,
      conversation: conversation,
      user_id: user_id
    } do
      {:ok, _, joined_socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      typing_key = "typing:#{user_id}"
      topic = "conversation:#{conversation.id}"

      {:ok, _ref} =
        WhisprMessagingWeb.Presence.track(joined_socket, typing_key, %{
          typing: true,
          conversation_id: conversation.id,
          started_at: System.system_time(:second)
        })

      assert Map.has_key?(WhisprMessagingWeb.Presence.list(topic), typing_key)

      # Simule le timeout: le channel doit traiter le message et untrack.
      send(joined_socket.channel_pid, {:stop_typing, user_id, conversation.id})

      # Laisse le channel process traiter le handle_info de facon synchrone.
      _ = :sys.get_state(joined_socket.channel_pid)

      refute Map.has_key?(WhisprMessagingWeb.Presence.list(topic), typing_key)
    end
  end

  # WHISPR-1390: le membre kick doit etre disconnect du channel (et pas
  # juste recevoir `member_removed`). Sans ca il continue a traiter
  # handle_in :send_message via son socket deja etabli.
  describe "force_leave (WHISPR-1390)" do
    test "le user cible recoit force_leave et son socket est ferme", %{
      socket: socket,
      conversation: conversation,
      user_id: user_id
    } do
      # Le channel est link au test process via subscribe_and_join. Quand
      # handle_out renvoie {:stop, :shutdown, _}, l'EXIT remonte vers
      # nous : on trap pour pouvoir l'observer sans crasher le test.
      Process.flag(:trap_exit, true)

      {:ok, _, joined_socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      channel_pid = joined_socket.channel_pid
      ref = Process.monitor(channel_pid)

      WhisprMessagingWeb.Endpoint.broadcast(
        "conversation:#{conversation.id}",
        "force_leave",
        %{user_id: user_id, reason: "kicked"}
      )

      assert_push "force_leave", %{user_id: ^user_id, reason: "kicked"}
      assert_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 1_000
    end

    test "un autre membre voit son socket survivre au force_leave d'un tiers", %{
      socket: socket,
      conversation: conversation,
      other_user_id: other_user_id
    } do
      {:ok, _, joined_socket} =
        subscribe_and_join(
          socket,
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      channel_pid = joined_socket.channel_pid
      ref = Process.monitor(channel_pid)

      WhisprMessagingWeb.Endpoint.broadcast(
        "conversation:#{conversation.id}",
        "force_leave",
        %{user_id: other_user_id, reason: "kicked"}
      )

      # Le socket courant ne doit pas etre stoppe (la cible est un autre user).
      refute_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 200
      assert Process.alive?(channel_pid)
    end
  end
end
