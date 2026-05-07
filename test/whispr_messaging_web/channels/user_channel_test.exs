defmodule WhisprMessagingWeb.UserChannelTest do
  @moduledoc """
  Tests for the per-user Phoenix channel. Exercises join authorisation,
  status updates, and conversation-listing handlers.
  """

  use WhisprMessagingWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Repo
  alias WhisprMessagingWeb.UserChannel
  alias WhisprMessagingWeb.UserSocket

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    {:ok, _} = Conversations.add_conversation_member(conversation.id, other_id)

    socket = socket(UserSocket, "user_socket:#{user_id}", %{user_id: user_id})

    %{
      socket: socket,
      user_id: user_id,
      other_id: other_id,
      conversation: conversation
    }
  end

  describe "join user:<id>" do
    test "succeeds when joining one's own channel", ctx do
      assert {:ok, %{user_id: uid}, _socket} =
               subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")

      assert uid == ctx.user_id
    end

    test "rejects joining another user's channel", ctx do
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.other_id}")
    end
  end

  describe "update_status" do
    test "accepts a valid status and replies with it", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
      ref = push(socket, "update_status", %{"status" => "away"})
      assert_reply(ref, :ok, %{status: "away"})
    end

    test "rejects an invalid status payload", ctx do
      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
      ref = push(socket, "update_status", %{"status" => "drunk"})
      assert_reply(ref, :error, %{reason: "invalid_status"})
    end
  end


  describe "get_unread_messages" do
    test "replies with the unread messages for the caller", ctx do
      {:ok, _} =
        Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.other_id,
          message_type: "text",
          content: "hi",
          client_random: System.unique_integer([:positive])
        })

      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
      ref = push(socket, "get_unread_messages", %{})
      assert_reply(ref, :ok, %{unread_messages: msgs})
      assert is_list(msgs)
    end
  end

  describe "mark_conversation_read" do
    test "marks the conversation as read for the user", ctx do
      {:ok, _} =
        Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.other_id,
          message_type: "text",
          content: "hi",
          client_random: System.unique_integer([:positive])
        })

      {:ok, _, socket} = subscribe_and_join(ctx.socket, UserChannel, "user:#{ctx.user_id}")
      ref = push(socket, "mark_conversation_read", %{"conversation_id" => ctx.conversation.id})

      assert_reply(ref, :ok, %{messages_marked: count})
      assert is_integer(count)

      # Drain spawned tasks so they don't leak into the next test.
      :timer.sleep(50)
    end
  end
end
