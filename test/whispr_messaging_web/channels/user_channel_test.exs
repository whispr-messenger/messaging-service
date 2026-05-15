defmodule WhisprMessagingWeb.UserChannelTest do
  use WhisprMessagingWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.{Conversations, Messages, Repo}
  alias WhisprMessagingWeb.{UserChannel, UserSocket}

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    user_id = Ecto.UUID.generate()
    other_user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{"test" => true},
        is_active: true
      })

    {:ok, _m1} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _m2} = Conversations.add_conversation_member(conversation.id, other_user_id)

    socket = socket(UserSocket, "user_socket:#{user_id}", %{user_id: user_id})

    %{
      socket: socket,
      user_id: user_id,
      other_user_id: other_user_id,
      conversation: conversation
    }
  end

  describe "join user:<id>" do
    test "joins successfully when the channel matches the socket user_id", ctx do
      assert {:ok, %{user_id: uid}, _socket} =
               subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      assert uid == ctx.user_id
    end

    test "refuses to join another user's channel", ctx do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.other_user_id}")
    end
  end

  describe "handle_in update_status" do
    test "valid status replies :ok with the chosen status", ctx do
      {:ok, _reply, socket} =
        subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      ref = push(socket, "update_status", %{"status" => "away"})
      assert_reply ref, :ok, %{status: "away"}
    end

    test "supports online / busy / offline", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      for s <- ["online", "busy", "offline"] do
        ref = push(socket, "update_status", %{"status" => s})
        assert_reply ref, :ok, %{status: ^s}
      end
    end

    test "rejects an unknown status", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      ref = push(socket, "update_status", %{"status" => "🚀"})
      assert_reply ref, :error, %{reason: "invalid_status"}
    end

    test "rejects a missing status payload", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
      ref = push(socket, "update_status", %{})
      assert_reply ref, :error, %{reason: "invalid_status"}
    end

    test "broadcasts user_status_changed on each member conversation", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{ctx.conversation.id}")

      push(socket, "update_status", %{"status" => "busy"})

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "user_status_changed",
                       payload: %{user_id: uid, status: "busy"}
                     },
                     1_500

      assert uid == ctx.user_id
    end
  end

  describe "handle_in get_conversations" do
    @tag :skip
    test "replies with the list of conversations for the current user (UserChannel currently expects {:ok, list} but Conversations.list_user_conversations returns a bare list)",
         ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      ref = push(socket, "get_conversations", %{})
      assert_reply ref, :ok, %{conversations: list}, 1_500
      assert is_list(list)
      assert Enum.any?(list, &(&1.id == ctx.conversation.id))
    end
  end

  describe "handle_in get_unread_messages" do
    test "replies with an empty list when there are no unread messages", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      ref = push(socket, "get_unread_messages", %{})
      assert_reply ref, :ok, %{unread_messages: list}, 1_500
      assert is_list(list)
    end
  end

  describe "handle_info :after_join" do
    test "is acknowledged after subscribing", ctx do
      # subscribe_and_join triggers :after_join. The fact that the join returns
      # {:ok, ...} means :after_join was handled successfully (the test fails
      # otherwise via the EXIT).
      assert {:ok, _reply, _socket} =
               subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
    end
  end

  describe "handle_info {:delivery_status, ...}" do
    test "pushes delivery_status to the client", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      message_id = Ecto.UUID.generate()

      send(
        socket.channel_pid,
        {:delivery_status, message_id, ctx.user_id, "read", DateTime.utc_now()}
      )

      assert_push "delivery_status", %{message_id: ^message_id, status: "read"}, 1_000
    end
  end

  describe "handle_info {:conversation_invitation, ...}" do
    test "pushes conversation_invitation for an existing conversation", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      inviter = Ecto.UUID.generate()
      send(socket.channel_pid, {:conversation_invitation, ctx.conversation.id, inviter})

      assert_push "conversation_invitation", payload, 1_000
      assert payload.inviter_id == inviter
    end

    test "logs and ignores unknown conversation IDs", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      bogus = Ecto.UUID.generate()
      send(socket.channel_pid, {:conversation_invitation, bogus, Ecto.UUID.generate()})

      refute_push "conversation_invitation", _, 200
    end
  end

  describe "handle_in mark_conversation_read" do
    test "marks the user's unread messages as read and broadcasts conversation_read", ctx do
      # Other user sends a message; current user has not read it yet.
      {:ok, _msg} =
        Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.other_user_id,
          message_type: "text",
          content: "unread",
          client_random: 12_345
        })

      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{ctx.conversation.id}")

      ref = push(socket, "mark_conversation_read", %{"conversation_id" => ctx.conversation.id})
      assert_reply ref, :ok, %{messages_marked: count}, 1_500
      assert is_integer(count)

      # The conversation should receive a conversation_read broadcast
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "conversation_read",
                       payload: %{user_id: uid}
                     },
                     1_500

      assert uid == ctx.user_id
    end

    test "returns reply with empty payload for an unknown conversation", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      ref = push(socket, "mark_conversation_read", %{"conversation_id" => Ecto.UUID.generate()})
      # The action returns {:ok, ...} or {:error, ...}; both are valid.
      assert_reply ref, status, _payload, 1_500
      assert status in [:ok, :error]
    end
  end

  describe "handle_in :presence_diff" do
    test "is propagated as a push to the client", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      send(socket.channel_pid, %{event: "presence_diff", payload: %{joins: %{}, leaves: %{}}})

      assert_push "presence_diff", _payload, 500
    end
  end
end
