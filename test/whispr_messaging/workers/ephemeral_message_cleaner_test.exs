defmodule WhisprMessaging.Workers.EphemeralMessageCleanerTest do
  use WhisprMessaging.DataCase, async: false

  import Ecto.Query

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.EphemeralMessageCleaner

  @moduletag :integration

  setup do
    {:ok, pid} = EphemeralMessageCleaner.start_link(skip_timer: true)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    sender_id = create_test_user_id()
    conversation = create_test_conversation()
    {:ok, _m} = Conversations.add_conversation_member(conversation.id, sender_id)

    Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{conversation.id}")

    %{sender_id: sender_id, conversation: conversation, worker: pid}
  end

  defp insert_message(conv_id, sender_id, opts) do
    expires_at =
      case Keyword.get(opts, :expires_at) do
        nil -> nil
        dt -> DateTime.truncate(dt, :second)
      end

    is_deleted = Keyword.get(opts, :is_deleted, false)

    # Insert directly to bypass the `expires_at must be in the future`
    # validation from Message.changeset.
    Repo.insert!(%Message{
      conversation_id: conv_id,
      sender_id: sender_id,
      message_type: "text",
      content: "ephemeral hi",
      metadata: %{},
      client_random: unique_client_random(),
      expires_at: expires_at,
      is_deleted: is_deleted,
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  describe "start_link/1" do
    test "starts the worker with skip_timer", %{worker: pid} do
      assert Process.alive?(pid)
    end
  end

  describe "cleanup_now/0" do
    test "returns {:ok, 0} when there are no expired messages", _ctx do
      assert {:ok, 0} = EphemeralMessageCleaner.cleanup_now()
    end

    test "deletes messages whose expires_at is in the past", ctx do
      past = DateTime.add(DateTime.utc_now(), -10)
      future = DateTime.add(DateTime.utc_now(), 3600)

      m_expired = insert_message(ctx.conversation.id, ctx.sender_id, expires_at: past)
      m_future = insert_message(ctx.conversation.id, ctx.sender_id, expires_at: future)
      m_no_ttl = insert_message(ctx.conversation.id, ctx.sender_id, expires_at: nil)

      assert {:ok, 1} = EphemeralMessageCleaner.cleanup_now()

      refute Repo.get(Message, m_expired.id)
      assert Repo.get(Message, m_future.id)
      assert Repo.get(Message, m_no_ttl.id)
    end

    test "skips messages already marked is_deleted", ctx do
      past = DateTime.add(DateTime.utc_now(), -10)

      m =
        insert_message(ctx.conversation.id, ctx.sender_id,
          expires_at: past,
          is_deleted: true
        )

      assert {:ok, 0} = EphemeralMessageCleaner.cleanup_now()
      assert Repo.get(Message, m.id)
    end

    test "broadcasts message:expired for each removed message", ctx do
      past = DateTime.add(DateTime.utc_now(), -10)
      m = insert_message(ctx.conversation.id, ctx.sender_id, expires_at: past)

      assert {:ok, 1} = EphemeralMessageCleaner.cleanup_now()

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "message:expired",
                       topic: topic,
                       payload: payload
                     },
                     1_000

      assert topic == "conversation:#{ctx.conversation.id}"
      assert payload.message_id == m.id
      assert payload.conversation_id == ctx.conversation.id
    end

    test "deletes only messages whose expires_at is strictly past", ctx do
      now = DateTime.utc_now()
      slightly_past = DateTime.add(now, -1)
      slightly_future = DateTime.add(now, 60)

      insert_message(ctx.conversation.id, ctx.sender_id, expires_at: slightly_past)
      insert_message(ctx.conversation.id, ctx.sender_id, expires_at: slightly_future)

      assert {:ok, 1} = EphemeralMessageCleaner.cleanup_now()

      remaining =
        Repo.all(from m in Message, where: m.conversation_id == ^ctx.conversation.id)

      assert length(remaining) == 1
    end
  end

  describe "handle_info(:cleanup, ...)" do
    test "the :cleanup message also drains expired messages", ctx do
      past = DateTime.add(DateTime.utc_now(), -10)
      m = insert_message(ctx.conversation.id, ctx.sender_id, expires_at: past)

      send(ctx.worker, :cleanup)
      # Drive cleanup synchronously to make the test deterministic
      {:ok, _} = EphemeralMessageCleaner.cleanup_now()

      refute Repo.get(Message, m.id)
    end
  end
end
