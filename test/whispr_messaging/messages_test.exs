defmodule WhisprMessaging.MessagesTest do
  # async: false volontairement: le setup du describe "new_message redis publish"
  # patche Application.put_env(:messaging_events_publisher, ...) ce qui est
  # global. Avec async: true, plusieurs tests clobberent le publisher en
  # concurrence et leakent des messages dans la mailbox des autres.
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.{Conversations, Messages}
  alias WhisprMessaging.Messages.Message

  describe "messages" do
    setup do
      # cree une conversation de test
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{"test" => true},
          is_active: true,
          e2ee_enabled: false
        })

      # ajoute les membres de test
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      %{
        conversation: conversation,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "create_message/1 creates a message with valid attributes", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      attrs = %{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "encrypted_test_content",
        client_random: 12_345,
        metadata: %{"test" => true}
      }

      assert {:ok, %Message{} = message} = Messages.create_message(attrs)
      assert message.conversation_id == conversation.id
      assert message.sender_id == user1_id
      assert message.message_type == "text"
      assert message.content == "encrypted_test_content"
      assert message.client_random == 12_345
      assert message.metadata == %{"test" => true}
      assert message.is_deleted == false
      assert message.sent_at != nil
    end

    test "create_message/1 fails with invalid attributes" do
      attrs = %{
        conversation_id: Ecto.UUID.generate(),
        sender_id: nil,
        message_type: "invalid_type",
        content: "",
        client_random: nil
      }

      assert {:error, %Ecto.Changeset{}} = Messages.create_message(attrs)
    end

    test "create_message/1 enforces unique client_random per sender", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      attrs = %{
        conversation_id: conversation.id,
        sender_id: user1_id,
        message_type: "text",
        content: "test_content",
        client_random: 12_345
      }

      # le premier message doit passer
      assert {:ok, _message1} = Messages.create_message(attrs)

      # le second avec le meme client_random doit echouer
      assert {:error, %Ecto.Changeset{}} = Messages.create_message(attrs)
    end

    test "get_message/1 returns message when it exists", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12_345
        })

      assert {:ok, fetched_message} = Messages.get_message(message.id)
      assert fetched_message.id == message.id
    end

    test "get_message/1 returns error when message doesn't exist" do
      assert {:error, :not_found} = Messages.get_message(Ecto.UUID.generate())
    end

    test "edit_message/4 updates message content", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 12_345
        })

      new_content = "updated_content"
      new_metadata = %{"edited" => true}

      assert {:ok, updated_message} =
               Messages.edit_message(message.id, user1_id, new_content, new_metadata)

      assert updated_message.content == new_content
      assert updated_message.metadata["edited"] == true
      assert updated_message.edited_at != nil
    end

    test "edit_message/4 fails when user is not the sender", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "original_content",
          client_random: 12_345
        })

      assert {:error, :forbidden} = Messages.edit_message(message.id, user2_id, "new_content")
    end

    test "delete_message/3 soft deletes a message", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12_345
        })

      assert {:ok, deleted_message} = Messages.delete_message(message.id, user1_id, true)
      assert deleted_message.is_deleted == true
      assert deleted_message.delete_for_everyone == true
    end

    test "list_recent_messages/3 returns messages in descending order", %{
      conversation: conversation,
      user1_id: user1_id
    } do
      # cree plusieurs messages avec des timestamps explicites pour garantir l'ordre
      base_time = DateTime.utc_now() |> DateTime.truncate(:second)

      _messages =
        for i <- 1..5 do
          {:ok, message} =
            Messages.create_message(%{
              conversation_id: conversation.id,
              sender_id: user1_id,
              message_type: "text",
              content: "content_#{i}",
              client_random: i,
              sent_at: DateTime.add(base_time, -i, :second)
            })

          message
        end

      # Messages crees :
      # 1 : now - 1s (le plus recent)
      # 2 : now - 2s
      # 3 : now - 3s
      # 4 : now - 4s
      # 5 : now - 5s (le plus ancien)
      # i=1 -> -1s, i=5 -> -5s, donc message 1 = plus recent, message 5 = plus ancien.
      # ordre desc (du plus recent au plus ancien) attendu : 1, 2, 3, 4, 5.

      recent_messages = Messages.list_recent_messages(conversation.id, 3)

      assert Enum.count(recent_messages) == 3
      # tri descendant par sent_at, 1 = le plus recent
      assert Enum.at(recent_messages, 0).client_random == 1
      assert Enum.at(recent_messages, 1).client_random == 2
      assert Enum.at(recent_messages, 2).client_random == 3
    end

    test "count_unread_messages/3 counts unread messages correctly", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # cree des messages de user1
      for i <- 1..3 do
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "content_#{i}",
          client_random: i
        })
      end

      # compte les non lus pour user2 (doit etre 3)
      unread_count = Messages.count_unread_messages(conversation.id, user2_id)
      assert unread_count == 3
    end
  end

  describe "new_message redis publish (WHISPR-1158)" do
    setup do
      # on injecte un dispatcher synchrone pour que le publish tourne inline et
      # ne survive pas au test (sinon il leak la connexion DB sandboxee).
      alias WhisprMessaging.Events.MessagingEvents, as: Events

      sync_dispatcher = fn message ->
        members = Conversations.list_conversation_members(message.conversation_id)
        Events.publish_new_message(message, members)
      end

      previous_dispatcher = Application.get_env(:whispr_messaging, :new_message_dispatcher)
      Application.put_env(:whispr_messaging, :new_message_dispatcher, sync_dispatcher)

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      sender_id = Ecto.UUID.generate()
      other_id = Ecto.UUID.generate()

      {:ok, _} = Conversations.add_conversation_member(conversation.id, sender_id)
      {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

      test_pid = self()

      publisher = fn channel, payload ->
        send(test_pid, {:redis_publish, channel, payload})
        {:ok, 1}
      end

      previous = Application.get_env(:whispr_messaging, :messaging_events_publisher)
      Application.put_env(:whispr_messaging, :messaging_events_publisher, publisher)

      on_exit(fn ->
        if previous do
          Application.put_env(:whispr_messaging, :messaging_events_publisher, previous)
        else
          Application.delete_env(:whispr_messaging, :messaging_events_publisher)
        end

        if previous_dispatcher do
          Application.put_env(:whispr_messaging, :new_message_dispatcher, previous_dispatcher)
        else
          Application.delete_env(:whispr_messaging, :new_message_dispatcher)
        end
      end)

      %{conversation: conversation, sender_id: sender_id, other_id: other_id}
    end

    test "publishes on whispr:messaging:new_message with recipients excluding the sender", %{
      conversation: conversation,
      sender_id: sender_id,
      other_id: other_id
    } do
      {:ok, _message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: sender_id,
          message_type: "text",
          content: "ciphertext",
          client_random: 99
        })

      assert_receive {:redis_publish, "whispr:messaging:new_message", json}, 1_000
      payload = Jason.decode!(json)

      assert payload["conversation_id"] == conversation.id
      assert payload["sender_id"] == sender_id
      assert payload["target_user_ids"] == [other_id]
      assert payload["message_type"] == "text"
      assert is_binary(payload["sent_at"])
    end

    test "publishes nothing when the conversation has only the sender", %{
      conversation: conversation,
      sender_id: sender_id,
      other_id: other_id
    } do
      # retire l'autre membre pour que l'envoyeur soit seul dans la conversation
      Conversations.remove_conversation_member(conversation.id, other_id)

      {:ok, _message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: sender_id,
          message_type: "text",
          content: "ciphertext",
          client_random: 101
        })

      refute_receive {:redis_publish, _channel, _json}, 200
    end
  end

  describe "reply threading validation" do
    setup do
      {:ok, conversation1} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      {:ok, conversation2} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user_id = Ecto.UUID.generate()

      {:ok, parent_message} =
        Messages.create_message(%{
          conversation_id: conversation1.id,
          sender_id: user_id,
          message_type: "text",
          content: "parent message",
          client_random: 10_001
        })

      %{
        conversation1: conversation1,
        conversation2: conversation2,
        user_id: user_id,
        parent_message: parent_message
      }
    end

    test "allows reply to message in same conversation", %{
      conversation1: conversation1,
      user_id: user_id,
      parent_message: parent_message
    } do
      assert {:ok, reply} =
               Messages.create_message(%{
                 conversation_id: conversation1.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "reply message",
                 client_random: 10_002,
                 reply_to_id: parent_message.id
               })

      assert reply.reply_to_id == parent_message.id
      assert reply.reply_to.id == parent_message.id
    end

    test "rejects reply to message in different conversation", %{
      conversation2: conversation2,
      user_id: user_id,
      parent_message: parent_message
    } do
      assert {:error, changeset} =
               Messages.create_message(%{
                 conversation_id: conversation2.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "cross-conversation reply",
                 client_random: 10_003,
                 reply_to_id: parent_message.id
               })

      assert %Ecto.Changeset{} = changeset
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
      assert errors[:reply_to_id] != nil
    end

    test "rejects reply to non-existent message", %{
      conversation1: conversation1,
      user_id: user_id
    } do
      fake_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Messages.create_message(%{
                 conversation_id: conversation1.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "reply to nothing",
                 client_random: 10_004,
                 reply_to_id: fake_id
               })

      assert %Ecto.Changeset{} = changeset
      errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
      assert errors[:reply_to_id] != nil
    end

    test "allows message without reply_to_id", %{
      conversation1: conversation1,
      user_id: user_id
    } do
      assert {:ok, message} =
               Messages.create_message(%{
                 conversation_id: conversation1.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "no reply",
                 client_random: 10_005
               })

      assert is_nil(message.reply_to_id)
    end
  end

  describe "delivery statuses" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, _member1} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = Conversations.add_conversation_member(conversation.id, user2_id)

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12_345
        })

      %{
        conversation: conversation,
        message: message,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "create_delivery_statuses_for_conversation/3 creates statuses for all members except sender",
         %{
           conversation: conversation,
           message: message,
           user1_id: user1_id
         } do
      assert {:ok, count} =
               Messages.create_delivery_statuses_for_conversation(
                 message.id,
                 conversation.id,
                 user1_id
               )

      # doit creer 1 delivery status (pour user2, l'envoyeur user1 est exclu)
      assert count == 1
    end

    test "mark_message_delivered/3 updates delivery status", %{
      message: message,
      user2_id: user2_id
    } do
      # on marque d'abord comme delivre
      assert {:ok, delivery_status} = Messages.mark_message_delivered(message.id, user2_id)
      assert delivery_status.delivered_at != nil
      assert delivery_status.read_at == nil
    end

    test "mark_message_read/3 updates read status and sets delivered if not set", %{
      message: message,
      user2_id: user2_id
    } do
      # marque comme lu sans avoir marque delivre avant
      assert {:ok, delivery_status} = Messages.mark_message_read(message.id, user2_id)
      assert delivery_status.read_at != nil
      # doit etre rempli automatiquement
      assert delivery_status.delivered_at != nil
    end

    test "get_message_delivery_status/2 returns 'sent' when no status exists", %{
      message: message,
      user2_id: user2_id
    } do
      assert Messages.get_message_delivery_status(message.id, user2_id) == "sent"
    end

    test "get_message_delivery_status/2 returns 'pending' after status creation", %{
      conversation: conversation,
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      Messages.create_delivery_statuses_for_conversation(
        message.id,
        conversation.id,
        user1_id
      )

      assert Messages.get_message_delivery_status(message.id, user2_id) == "pending"
    end

    test "get_message_delivery_status/2 returns 'delivered' after delivery", %{
      message: message,
      user2_id: user2_id
    } do
      Messages.mark_message_delivered(message.id, user2_id)
      assert Messages.get_message_delivery_status(message.id, user2_id) == "delivered"
    end

    test "get_message_delivery_status/2 returns 'read' after reading", %{
      message: message,
      user2_id: user2_id
    } do
      Messages.mark_message_read(message.id, user2_id)
      assert Messages.get_message_delivery_status(message.id, user2_id) == "read"
    end

    test "get_aggregate_delivery_status/1 returns 'sent' when no statuses exist", %{
      message: message
    } do
      assert Messages.get_aggregate_delivery_status(message.id) == "sent"
    end

    test "get_aggregate_delivery_status/1 returns correct aggregate", %{
      conversation: conversation,
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      Messages.create_delivery_statuses_for_conversation(
        message.id,
        conversation.id,
        user1_id
      )

      # au depart : pending
      assert Messages.get_aggregate_delivery_status(message.id) == "pending"

      # apres delivery
      Messages.mark_message_delivered(message.id, user2_id)
      assert Messages.get_aggregate_delivery_status(message.id) == "delivered"

      # apres lecture
      Messages.mark_message_read(message.id, user2_id)
      assert Messages.get_aggregate_delivery_status(message.id) == "read"
    end

    test "mark_conversation_read/3 marks all messages as read" do
      _conversation_id = Ecto.UUID.generate()
      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      # vraie conversation pour respecter les contraintes DB
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      # ajoute les membres
      {:ok, _} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _} = WhisprMessaging.Conversations.add_conversation_member(conversation.id, user2_id)

      conversation_id = conversation.id

      # cree les messages
      for i <- 1..3 do
        {:ok, message} =
          Messages.create_message(%{
            conversation_id: conversation_id,
            sender_id: user1_id,
            message_type: "text",
            content: "msg #{i}",
            client_random: i
          })

        # cree un delivery status pour user2
        Messages.create_delivery_statuses_for_conversation(message.id, conversation_id, user1_id)
      end

      # marque comme lu
      assert {:ok, count} = Messages.mark_conversation_read(conversation_id, user2_id)
      assert count == 3

      # verifie les timestamps
      statuses = WhisprMessaging.Repo.all(WhisprMessaging.Messages.DeliveryStatus)
      assert Enum.count(statuses) == 3
      assert Enum.all?(statuses, fn s -> s.read_at != nil end)
    end

    # WHISPR-1304: tests du mark_unread (revert d'un mark_read)
    test "mark_message_unread/2 repasse read_at a nil et garde delivered_at", %{
      message: message,
      user2_id: user2_id
    } do
      # marque comme lu (pose read_at + delivered_at)
      assert {:ok, %{read_at: read_at, delivered_at: delivered_at}} =
               Messages.mark_message_read(message.id, user2_id)

      assert read_at != nil
      assert delivered_at != nil

      # revert
      assert {:ok, delivery_status} = Messages.mark_message_unread(message.id, user2_id)
      assert delivery_status.read_at == nil
      # delivered_at est garde - le message a ete livre, c'est juste son
      # etat "lu" qui est revert
      assert delivery_status.delivered_at != nil
    end

    test "mark_message_unread/2 renvoie :not_found quand il n'y a aucun delivery_status", %{
      message: message
    } do
      ghost_user = Ecto.UUID.generate()
      assert {:error, :not_found} = Messages.mark_message_unread(message.id, ghost_user)
    end

    test "mark_unread/2 revert read_at + rewind last_read_at du membre", %{
      conversation: conversation,
      message: message,
      user2_id: user2_id
    } do
      # le user2 marque le message comme lu
      assert {:ok, _} = Messages.mark_message_read(message.id, user2_id)
      member = Conversations.get_conversation_member(conversation.id, user2_id)
      Conversations.mark_member_read(member)

      # revert
      assert {:ok, %{id: returned_id}} = Messages.mark_unread(message.id, user2_id)
      assert returned_id == message.id

      # delivery_status a read_at = nil
      delivery_status =
        WhisprMessaging.Repo.get_by(WhisprMessaging.Messages.DeliveryStatus,
          message_id: message.id,
          user_id: user2_id
        )

      assert delivery_status.read_at == nil

      # last_read_at du membre est rewind avant le sent_at du message
      refreshed_member = Conversations.get_conversation_member(conversation.id, user2_id)

      assert refreshed_member.last_read_at == nil or
               DateTime.compare(refreshed_member.last_read_at, message.sent_at) == :lt
    end

    test "mark_unread/2 renvoie :not_found quand le message n'existe pas" do
      ghost_message = Ecto.UUID.generate()
      ghost_user = Ecto.UUID.generate()
      assert {:error, :not_found} = Messages.mark_unread(ghost_message, ghost_user)
    end

    test "mark_unread/2 rollback last_read_at si delivery_status n'existe pas",
         %{conversation: conversation, message: message} do
      # WHISPR-1315 : si mark_message_unread fail (pas de delivery_status),
      # on rollback la transaction donc last_read_at du membre n est pas modifie.
      ghost_user = Ecto.UUID.generate()

      {:ok, _} = Conversations.add_conversation_member(conversation.id, ghost_user)

      member = Conversations.get_conversation_member(conversation.id, ghost_user)
      original_last_read = member.last_read_at

      assert {:error, :not_found} = Messages.mark_unread(message.id, ghost_user)

      refreshed = Conversations.get_conversation_member(conversation.id, ghost_user)
      assert refreshed.last_read_at == original_last_read
    end
  end

  describe "reactions" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "test_content",
          client_random: 12_345
        })

      %{
        conversation: conversation,
        message: message,
        user1_id: user1_id,
        user2_id: user2_id
      }
    end

    test "add_reaction/3 adds a reaction to a message", %{
      message: message,
      user2_id: user2_id
    } do
      assert {:ok, reaction} = Messages.add_reaction(message.id, user2_id, "👍")
      assert reaction.message_id == message.id
      assert reaction.user_id == user2_id
      assert reaction.reaction == "👍"
    end

    test "add_reaction/3 prevents duplicate reactions", %{
      message: message,
      user2_id: user2_id
    } do
      # la premiere reaction doit passer
      assert {:ok, _reaction} = Messages.add_reaction(message.id, user2_id, "👍")

      # reaction dupliquee : doit echouer
      assert {:error, %Ecto.Changeset{}} = Messages.add_reaction(message.id, user2_id, "👍")
    end

    test "remove_reaction/3 removes a reaction", %{
      message: message,
      user2_id: user2_id
    } do
      # ajoute la reaction
      {:ok, _reaction} = Messages.add_reaction(message.id, user2_id, "👍")

      # retire la reaction
      assert {:ok, :deleted} = Messages.remove_reaction(message.id, user2_id, "👍")

      # nouvelle tentative de retrait : doit echouer
      assert {:error, :not_found} = Messages.remove_reaction(message.id, user2_id, "👍")
    end

    test "get_reaction_summary/1 returns reaction counts", %{
      message: message,
      user1_id: user1_id,
      user2_id: user2_id
    } do
      # ajoute plusieurs reactions
      Messages.add_reaction(message.id, user1_id, "👍")
      Messages.add_reaction(message.id, user2_id, "👍")
      Messages.add_reaction(message.id, user1_id, "❤️")

      summary = Messages.get_reaction_summary(message.id)

      assert summary["👍"] == 2
      assert summary["❤️"] == 1
    end
  end

  describe "message helpers" do
    test "create_text_message/5 creates a text message" do
      _conversation_id = Ecto.UUID.generate()
      sender_id = Ecto.UUID.generate()

      # il faut une vraie conversation pour les FK
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      # remplace conversation_id par celui de la vraie conversation
      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_text_message(
                 conversation_id,
                 sender_id,
                 "encrypted_content",
                 12_345,
                 %{
                   "test" => true
                 }
               )

      assert message.message_type == "text"
      assert message.content == "encrypted_content"
      assert message.client_random == 12_345
      assert message.metadata["test"] == true
    end

    test "create_media_message/5 creates a media message" do
      _conversation_id = Ecto.UUID.generate()
      sender_id = Ecto.UUID.generate()

      # il faut une vraie conversation
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_media_message(
                 conversation_id,
                 sender_id,
                 "encrypted_url",
                 67_890,
                 %{
                   "width" => 800
                 }
               )

      assert message.message_type == "media"
      assert message.content == "encrypted_url"
      assert message.metadata["width"] == 800
    end

    test "create_system_message/3 creates a system message" do
      _conversation_id = Ecto.UUID.generate()

      # il faut une vraie conversation
      {:ok, conversation} =
        WhisprMessaging.Conversations.create_conversation(%{
          type: "group",
          metadata: %{"name" => "System Group"},
          is_active: true,
          e2ee_enabled: false
        })

      conversation_id = conversation.id

      assert {:ok, message} =
               Messages.create_system_message(
                 conversation_id,
                 "User joined",
                 %{"action" => "join"}
               )

      assert message.message_type == "system"
      assert message.content == "User joined"
      assert message.sender_id == "00000000-0000-0000-0000-000000000000"
    end
  end

  # ---------------------------------------------------------------------------
  # Tests messages ephemeres (WHISPR-469)
  # ---------------------------------------------------------------------------

  describe "ephemeral messages" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user_id = Ecto.UUID.generate()
      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "creates a message with expires_at", %{conversation: c, user_id: user_id} do
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)

      assert {:ok, message} =
               Messages.create_message(%{
                 conversation_id: c.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "ephemeral",
                 client_random: 42,
                 expires_at: expires_at
               })

      assert message.expires_at == expires_at
      assert Message.expired?(message) == false
    end

    test "expired?/1 returns true for a message past its expiry" do
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      message = %Message{expires_at: past}
      assert Message.expired?(message) == true
    end

    test "expired?/1 returns false for non-ephemeral messages" do
      message = %Message{expires_at: nil}
      assert Message.expired?(message) == false
    end

    test "rejects expires_at in the past", %{conversation: c, user_id: user_id} do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Messages.create_message(%{
                 conversation_id: c.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "ephemeral",
                 client_random: 43,
                 expires_at: past
               })

      assert "must be in the future" in errors_on(changeset).expires_at
    end

    test "recent_messages_query excludes expired messages", %{
      conversation: c,
      user_id: user_id
    } do
      past = DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      future = DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)

      # insere un message non-ephemere
      {:ok, normal_msg} =
        Messages.create_message(%{
          conversation_id: c.id,
          sender_id: user_id,
          message_type: "text",
          content: "normal",
          client_random: 100
        })

      # insere un message ephemere valide (expiration future)
      {:ok, live_ephemeral} =
        Messages.create_message(%{
          conversation_id: c.id,
          sender_id: user_id,
          message_type: "text",
          content: "live",
          client_random: 101,
          expires_at: future
        })

      # insere directement un message deja expire (bypass de la validation)
      expired_id = Ecto.UUID.generate()

      WhisprMessaging.Repo.insert_all("messages", [
        %{
          id: Ecto.UUID.dump!(expired_id),
          conversation_id: Ecto.UUID.dump!(c.id),
          sender_id: Ecto.UUID.dump!(user_id),
          message_type: "text",
          content: "expired",
          client_random: 102,
          sent_at: DateTime.utc_now(),
          is_deleted: false,
          delete_for_everyone: false,
          metadata: "{}",
          expires_at: past,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      messages =
        Message.recent_messages_query(c.id, 50)
        |> WhisprMessaging.Repo.all()

      ids = Enum.map(messages, & &1.id)
      assert normal_msg.id in ids
      assert live_ephemeral.id in ids
      refute expired_id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # Tests brouillons (WHISPR-471)
  # ---------------------------------------------------------------------------

  describe "drafts" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user_id = Ecto.UUID.generate()
      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      %{conversation: conversation, user_id: user_id}
    end

    test "upsert_draft/3 creates a draft", %{conversation: c, user_id: user_id} do
      assert {:ok, draft} = Messages.upsert_draft(c.id, user_id, "draft content")
      assert draft.conversation_id == c.id
      assert draft.user_id == user_id
      assert draft.content == "draft content"
    end

    test "upsert_draft/3 replaces existing draft", %{conversation: c, user_id: user_id} do
      {:ok, _first} = Messages.upsert_draft(c.id, user_id, "first draft")
      {:ok, second} = Messages.upsert_draft(c.id, user_id, "updated draft")
      assert second.content == "updated draft"
      {:ok, fetched} = Messages.get_draft(c.id, user_id)
      assert fetched.content == "updated draft"
    end

    test "get_draft/2 returns draft when it exists", %{conversation: c, user_id: user_id} do
      {:ok, _draft} = Messages.upsert_draft(c.id, user_id, "my draft")
      assert {:ok, draft} = Messages.get_draft(c.id, user_id)
      assert draft.content == "my draft"
    end

    test "get_draft/2 returns not_found when no draft exists", %{conversation: c} do
      other_user = Ecto.UUID.generate()
      assert {:error, :not_found} = Messages.get_draft(c.id, other_user)
    end

    test "delete_draft/2 deletes owned draft", %{conversation: c, user_id: user_id} do
      {:ok, draft} = Messages.upsert_draft(c.id, user_id, "to delete")
      assert {:ok, _} = Messages.delete_draft(draft.id, user_id)
      assert {:error, :not_found} = Messages.get_draft(c.id, user_id)
    end

    test "delete_draft/2 returns forbidden for another user's draft", %{
      conversation: c,
      user_id: user_id
    } do
      {:ok, draft} = Messages.upsert_draft(c.id, user_id, "not yours")
      other_user = Ecto.UUID.generate()
      assert {:error, :forbidden} = Messages.delete_draft(draft.id, other_user)
    end

    test "delete_draft/2 returns not_found for missing draft", %{user_id: user_id} do
      assert {:error, :not_found} = Messages.delete_draft(Ecto.UUID.generate(), user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests messages programmes (WHISPR-470)
  # ---------------------------------------------------------------------------

  describe "scheduled messages" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user_id = Ecto.UUID.generate()
      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      %{conversation: conversation, user_id: user_id, future: future}
    end

    test "schedule_message/1 creates a scheduled message", %{
      conversation: c,
      user_id: user_id,
      future: future
    } do
      assert {:ok, sm} =
               Messages.schedule_message(%{
                 conversation_id: c.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "hello future",
                 client_random: 5001,
                 scheduled_at: future
               })

      assert sm.status == "pending"
      assert sm.scheduled_at == future
      assert sm.sender_id == user_id
    end

    test "schedule_message/1 rejects scheduled_at in the past", %{
      conversation: c,
      user_id: user_id
    } do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Messages.schedule_message(%{
                 conversation_id: c.id,
                 sender_id: user_id,
                 message_type: "text",
                 content: "late",
                 client_random: 5002,
                 scheduled_at: past
               })

      assert "must be in the future" in errors_on(changeset).scheduled_at
    end

    test "list_scheduled_messages/1 returns pending messages for sender", %{
      conversation: c,
      user_id: user_id,
      future: future
    } do
      {:ok, _} =
        Messages.schedule_message(%{
          conversation_id: c.id,
          sender_id: user_id,
          message_type: "text",
          content: "msg1",
          client_random: 5010,
          scheduled_at: future
        })

      messages = Messages.list_scheduled_messages(user_id)
      refute Enum.empty?(messages)
      assert Enum.all?(messages, &(&1.status == "pending"))
    end

    test "cancel_scheduled_message/2 cancels a pending message", %{
      conversation: c,
      user_id: user_id,
      future: future
    } do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: c.id,
          sender_id: user_id,
          message_type: "text",
          content: "cancel me",
          client_random: 5020,
          scheduled_at: future
        })

      assert {:ok, cancelled} = Messages.cancel_scheduled_message(sm.id, user_id)
      assert cancelled.status == "cancelled"
    end

    test "cancel_scheduled_message/2 returns forbidden for another user", %{
      conversation: c,
      user_id: user_id,
      future: future
    } do
      {:ok, sm} =
        Messages.schedule_message(%{
          conversation_id: c.id,
          sender_id: user_id,
          message_type: "text",
          content: "not yours",
          client_random: 5030,
          scheduled_at: future
        })

      other_user = Ecto.UUID.generate()
      assert {:error, :forbidden} = Messages.cancel_scheduled_message(sm.id, other_user)
    end

    test "cancel_scheduled_message/2 returns not_found for missing message", %{user_id: user_id} do
      assert {:error, :not_found} =
               Messages.cancel_scheduled_message(Ecto.UUID.generate(), user_id)
    end
  end

  describe "pinned messages" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user_id = Ecto.UUID.generate()
      {:ok, _member} = Conversations.add_conversation_member(conversation.id, user_id)

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "pin me",
          client_random: 9001
        })

      %{conversation: conversation, user_id: user_id, message: message}
    end

    test "pin_message/2 pins a message", %{message: message, user_id: user_id} do
      assert {:ok, pinned} = Messages.pin_message(message.id, user_id)
      assert pinned.message_id == message.id
      assert pinned.pinned_by == user_id
    end

    test "pin_message/2 prevents pinning the same message twice", %{
      message: message,
      user_id: user_id
    } do
      assert {:ok, _} = Messages.pin_message(message.id, user_id)
      assert {:error, changeset} = Messages.pin_message(message.id, user_id)
      refute changeset.valid?
    end

    test "unpin_message/1 removes the pin", %{message: message, user_id: user_id} do
      {:ok, _} = Messages.pin_message(message.id, user_id)
      assert {:ok, :unpinned} = Messages.unpin_message(message.id)
      assert {:error, :not_found} = Messages.unpin_message(message.id)
    end

    test "list_pinned_messages/1 returns only pinned, non-deleted messages", %{
      conversation: conversation,
      user_id: user_id,
      message: message
    } do
      {:ok, other} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "not pinned",
          client_random: 9002
        })

      {:ok, _} = Messages.pin_message(message.id, user_id)
      {:ok, _} = Messages.pin_message(other.id, user_id)

      # un delete global doit retirer le pin de la liste
      {:ok, _} = Messages.delete_message(other.id, user_id, true)

      pins = Messages.list_pinned_messages(conversation.id)
      assert Enum.count(pins) == 1
      assert hd(pins).message_id == message.id
    end

    test "delete_message/3 with delete_for_everyone auto-unpins", %{
      message: message,
      user_id: user_id,
      conversation: conversation
    } do
      {:ok, _} = Messages.pin_message(message.id, user_id)
      {:ok, _} = Messages.delete_message(message.id, user_id, true)
      assert Messages.list_pinned_messages(conversation.id) == []
    end
  end

  describe "per-user message deletion" do
    setup do
      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      user1_id = Ecto.UUID.generate()
      user2_id = Ecto.UUID.generate()
      {:ok, _} = Conversations.add_conversation_member(conversation.id, user1_id)
      {:ok, _} = Conversations.add_conversation_member(conversation.id, user2_id)

      {:ok, message} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user1_id,
          message_type: "text",
          content: "visible or not",
          client_random: 9100
        })

      %{
        conversation: conversation,
        user1_id: user1_id,
        user2_id: user2_id,
        message: message
      }
    end

    test "delete for me hides message only for that user", %{
      conversation: conversation,
      user1_id: user1_id,
      user2_id: user2_id,
      message: message
    } do
      assert {:ok, _} = Messages.delete_message(message.id, user2_id, false)

      user1_list = Messages.list_recent_messages(conversation.id, 50, nil, user1_id)
      user2_list = Messages.list_recent_messages(conversation.id, 50, nil, user2_id)

      assert Enum.any?(user1_list, &(&1.id == message.id))
      refute Enum.any?(user2_list, &(&1.id == message.id))
    end

    test "delete for me is idempotent", %{message: message, user2_id: user2_id} do
      assert {:ok, _} = Messages.delete_message(message.id, user2_id, false)
      assert {:ok, _} = Messages.delete_message(message.id, user2_id, false)
    end

    test "delete for everyone requires the sender", %{
      message: message,
      user2_id: user2_id
    } do
      assert {:error, :forbidden} = Messages.delete_message(message.id, user2_id, true)
    end
  end

  describe "search_messages_global/4" do
    setup do
      user_id = Ecto.UUID.generate()
      other_user_id = Ecto.UUID.generate()

      {:ok, conversation} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)

      {:ok, foreign_conv} =
        Conversations.create_conversation(%{
          type: "direct",
          metadata: %{},
          is_active: true,
          e2ee_enabled: false
        })

      {:ok, _} = Conversations.add_conversation_member(foreign_conv.id, other_user_id)

      {:ok, hello} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "hello world",
          client_random: 9200
        })

      {:ok, _unrelated} =
        Messages.create_message(%{
          conversation_id: conversation.id,
          sender_id: user_id,
          message_type: "text",
          content: "goodbye world",
          client_random: 9201
        })

      {:ok, _foreign} =
        Messages.create_message(%{
          conversation_id: foreign_conv.id,
          sender_id: other_user_id,
          message_type: "text",
          content: "hello stranger",
          client_random: 9202
        })

      %{user_id: user_id, hello: hello}
    end

    test "returns matches only from user's own conversations", %{user_id: user_id, hello: hello} do
      results = Messages.search_messages_global(user_id, "hello")
      assert Enum.count(results) == 1
      assert hd(results).id == hello.id
    end

    test "escapes LIKE wildcards to prevent injection", %{user_id: user_id} do
      # `%` doit matcher au sens litteral et pas etre interprete comme wildcard.
      # aucun message ne contient `%` litteral, donc le resultat doit etre vide.
      assert Messages.search_messages_global(user_id, "%") == []
    end

    test "excludes messages the user has deleted for themselves", %{
      user_id: user_id,
      hello: hello
    } do
      {:ok, _} = Messages.delete_message(hello.id, user_id, false)
      assert Messages.search_messages_global(user_id, "hello") == []
    end

    # WHISPR-1061
    test "filters by conversation_id when provided", %{user_id: user_id, hello: hello} do
      other_conv_id = Ecto.UUID.generate()

      # filtre par une conversation dont l'user n'est meme pas membre -> vide
      assert [] =
               Messages.search_messages_global(user_id, "hello", conversation_id: other_conv_id)

      # filtre par la conversation qui contient vraiment le match -> hit
      results =
        Messages.search_messages_global(user_id, "hello", conversation_id: hello.conversation_id)

      assert Enum.count(results) == 1
      assert hd(results).id == hello.id
    end

    test "filters by message_type when provided", %{user_id: user_id, hello: hello} do
      assert [hit] = Messages.search_messages_global(user_id, "hello", message_type: "text")
      assert hit.id == hello.id

      assert [] = Messages.search_messages_global(user_id, "hello", message_type: "media")
    end

    test "respects limit and offset", %{user_id: user_id} do
      page1 = Messages.search_messages_global(user_id, "world", limit: 1, offset: 0)
      page2 = Messages.search_messages_global(user_id, "world", limit: 1, offset: 1)

      assert Enum.count(page1) == 1
      assert Enum.count(page2) == 1
      refute hd(page1).id == hd(page2).id
    end
  end

  describe "build_match_preview/2 (WHISPR-1061)" do
    test "returns nil for an empty query" do
      assert Messages.build_match_preview("hello world", "") == nil
      assert Messages.build_match_preview("hello world", "   ") == nil
    end

    test "returns nil when the query isn't present in the content" do
      assert Messages.build_match_preview("hello", "nope") == nil
    end

    test "matches case-insensitively and reports position within the excerpt" do
      result = Messages.build_match_preview("Hello World", "WORLD")
      assert result.match_length == 5
      assert String.slice(result.excerpt, result.match_start, 5) == "World"
    end

    test "clips to a ~40-char radius around the match" do
      content = String.duplicate("a", 100) <> "needle" <> String.duplicate("b", 100)
      result = Messages.build_match_preview(content, "needle")
      # taille extrait : environ 40 + len(needle) + 40 = 86
      assert byte_size(result.excerpt) <= 86
      assert String.slice(result.excerpt, result.match_start, result.match_length) == "needle"
    end
  end
end
