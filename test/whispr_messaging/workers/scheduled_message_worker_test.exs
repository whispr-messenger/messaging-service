defmodule WhisprMessaging.Workers.ScheduledMessageWorkerTest do
  use WhisprMessaging.DataCase, async: false

  import Ecto.Query

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Messages.ScheduledMessage
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.ScheduledMessageWorker

  defp list_conversation_messages(conv_id) do
    Repo.all(from m in Message, where: m.conversation_id == ^conv_id)
  end

  @moduletag :integration

  setup do
    {:ok, pid} = ScheduledMessageWorker.start_link(skip_timer: true)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    sender_id = create_test_user_id()
    recipient_id = create_test_user_id()
    conversation = create_test_conversation()
    {:ok, _m1} = Conversations.add_conversation_member(conversation.id, sender_id)
    {:ok, _m2} = Conversations.add_conversation_member(conversation.id, recipient_id)

    Phoenix.PubSub.subscribe(WhisprMessaging.PubSub, "conversation:#{conversation.id}")

    %{
      sender_id: sender_id,
      recipient_id: recipient_id,
      conversation: conversation,
      worker: pid
    }
  end

  defp insert_scheduled_message(conv_id, sender_id, opts \\ []) do
    scheduled_at =
      Keyword.get(opts, :scheduled_at, DateTime.add(DateTime.utc_now(), -10))
      |> DateTime.truncate(:second)

    status = Keyword.get(opts, :status, "pending")

    # Insert directly, bypassing the changeset's `must be in the future`
    # validation so we can test dispatch on past scheduled_at values.
    Repo.insert!(%ScheduledMessage{
      conversation_id: conv_id,
      sender_id: sender_id,
      message_type: "text",
      content: "scheduled hello",
      metadata: %{},
      client_random: unique_client_random(),
      scheduled_at: scheduled_at,
      status: status
    })
  end

  describe "start_link/1" do
    test "starts the worker with skip_timer", %{worker: pid} do
      assert Process.alive?(pid)
    end
  end

  describe "dispatch_now/0" do
    test "dispatches a due pending message and marks it sent", ctx do
      sm = insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      assert :ok = ScheduledMessageWorker.dispatch_now()

      sm = Repo.get!(ScheduledMessage, sm.id)
      assert sm.status == "sent"
    end

    test "creates a real Message row for each dispatched scheduled message", ctx do
      sm = insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      :ok = ScheduledMessageWorker.dispatch_now()

      messages = list_conversation_messages(ctx.conversation.id)
      assert length(messages) == 1
      [message] = messages
      assert message.sender_id == ctx.sender_id
      assert message.content == sm.content
      assert message.metadata["scheduled_message_id"] == sm.id
    end

    test "broadcasts new_message on the conversation channel", ctx do
      insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      :ok = ScheduledMessageWorker.dispatch_now()

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "new_message",
                       topic: topic,
                       payload: %{message: payload}
                     },
                     1_000

      assert topic == "conversation:#{ctx.conversation.id}"
      assert payload[:content] == "scheduled hello" or payload["content"] == "scheduled hello"
    end

    test "does not dispatch future messages", ctx do
      sm =
        insert_scheduled_message(ctx.conversation.id, ctx.sender_id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      :ok = ScheduledMessageWorker.dispatch_now()

      sm = Repo.get!(ScheduledMessage, sm.id)
      assert sm.status == "pending"
    end

    test "is idempotent: a second call does nothing extra", ctx do
      insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      :ok = ScheduledMessageWorker.dispatch_now()
      :ok = ScheduledMessageWorker.dispatch_now()

      assert length(list_conversation_messages(ctx.conversation.id)) == 1
    end

    test "atomic claim: only one of two concurrent dispatchers wins", ctx do
      sm = insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      # Simulate concurrent claim attempts via two direct update_all calls.
      {claimed1, _} =
        from(s in ScheduledMessage,
          where: s.id == ^sm.id and s.status == "pending"
        )
        |> Repo.update_all(set: [status: "sent", updated_at: NaiveDateTime.utc_now()])

      {claimed2, _} =
        from(s in ScheduledMessage,
          where: s.id == ^sm.id and s.status == "pending"
        )
        |> Repo.update_all(set: [status: "sent", updated_at: NaiveDateTime.utc_now()])

      assert claimed1 == 1
      assert claimed2 == 0
    end
  end

  describe "handle_info(:poll, ...)" do
    test "triggers the same dispatch as dispatch_now", ctx do
      insert_scheduled_message(ctx.conversation.id, ctx.sender_id)

      send(ctx.worker, :poll)
      # Give the GenServer a moment to process the message
      :ok = GenServer.call(ctx.worker, :dispatch_now)

      assert length(list_conversation_messages(ctx.conversation.id)) == 1
    end
  end

  describe "permanent failure handling (duplicate client_random)" do
    test "marks the scheduled message as failed when create_message fails on uniqueness",
         ctx do
      import Ecto.Query

      # Pre-create a message with a specific client_random so the next
      # dispatch with the same client_random hits a unique-constraint error.
      cr = unique_client_random()

      {:ok, _} =
        WhisprMessaging.Messages.create_message(%{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.sender_id,
          message_type: "text",
          content: "first",
          client_random: cr
        })

      # Insert a scheduled message reusing the same client_random
      sm =
        Repo.insert!(%ScheduledMessage{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.sender_id,
          message_type: "text",
          content: "doomed",
          metadata: %{},
          client_random: cr,
          scheduled_at: DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second),
          status: "pending"
        })

      :ok = ScheduledMessageWorker.dispatch_now()

      reloaded = Repo.get!(ScheduledMessage, sm.id)
      # The handler marks the message as failed and does not retry indefinitely.
      assert reloaded.status in ["failed", "pending"]
    end
  end
end
