defmodule WhisprMessaging.Workers.ScheduledMessageWorkerTest do
  @moduledoc """
  Tests the dispatch loop of the scheduled-message worker. We invoke
  `dispatch_due_messages/0` directly instead of waiting for the scheduled
  poll so the assertions are deterministic.
  """

  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.ScheduledMessage
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.ScheduledMessageWorker

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true,
        e2ee_enabled: false
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)

    %{user_id: user_id, conversation: conversation}
  end

  defp insert_due_message(ctx, opts \\ []) do
    {:ok, sm} =
      Repo.insert(
        ScheduledMessage.changeset(%ScheduledMessage{}, %{
          conversation_id: ctx.conversation.id,
          sender_id: ctx.user_id,
          content: Keyword.get(opts, :content, "due"),
          message_type: "text",
          client_random: Keyword.get(opts, :client_random, System.unique_integer([:positive])),
          # Future to pass changeset validation
          scheduled_at: DateTime.utc_now() |> DateTime.add(3600, :second)
        })
      )

    # Force the row backwards so the worker considers it due.
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    sm
    |> Ecto.Changeset.cast(%{scheduled_at: past}, [:scheduled_at])
    |> Repo.update!()
  end

  test "dispatches due messages by creating real messages and marking them sent", ctx do
    sm = insert_due_message(ctx)

    ScheduledMessageWorker.dispatch_due_messages()

    reloaded = Repo.get!(ScheduledMessage, sm.id)
    assert reloaded.status == "sent"

    # The corresponding message exists in the conversation
    [message] = Messages.list_recent_messages(ctx.conversation.id, 50)
    assert message.sender_id == ctx.user_id
    assert message.metadata["scheduled_message_id"] == sm.id
  end

  test "leaves cancelled scheduled messages alone", ctx do
    sm = insert_due_message(ctx)
    {:ok, _} = Messages.cancel_scheduled_message(sm.id, ctx.user_id)

    ScheduledMessageWorker.dispatch_due_messages()

    reloaded = Repo.get!(ScheduledMessage, sm.id)
    assert reloaded.status == "cancelled"
  end

  test "no-op when no messages are due", _ctx do
    ScheduledMessageWorker.dispatch_due_messages()
  end
end
