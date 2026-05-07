defmodule WhisprMessaging.Workers.EphemeralMessageCleanerTest do
  @moduledoc """
  Tests for the ephemeral message cleanup worker.
  Bypasses the GenServer timer by calling `delete_expired_messages/0` directly.
  """

  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.EphemeralMessageCleaner

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    user_id = Ecto.UUID.generate()

    {:ok, conversation} =
      Conversations.create_conversation(%{
        type: "direct",
        metadata: %{},
        is_active: true
      })

    {:ok, _} = Conversations.add_conversation_member(conversation.id, user_id)
    %{user_id: user_id, conversation: conversation}
  end

  defp insert_message_with_expiry(ctx, expires_at) do
    {:ok, message} =
      Messages.create_message(%{
        conversation_id: ctx.conversation.id,
        sender_id: ctx.user_id,
        message_type: "text",
        content: "ephemeral",
        client_random: System.unique_integer([:positive])
      })

    message
    |> Ecto.Changeset.cast(%{expires_at: expires_at}, [:expires_at])
    |> Repo.update!()
  end

  test "deletes messages whose expires_at is in the past", ctx do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    expired = insert_message_with_expiry(ctx, past)

    deleted = EphemeralMessageCleaner.delete_expired_messages()

    assert deleted >= 1
    assert is_nil(Repo.get(Message, expired.id))
  end

  test "leaves messages with future expires_at intact", ctx do
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    fresh = insert_message_with_expiry(ctx, future)

    EphemeralMessageCleaner.delete_expired_messages()

    assert Repo.get(Message, fresh.id) != nil
  end

  test "returns 0 when there is nothing to clean", _ctx do
    assert 0 == EphemeralMessageCleaner.delete_expired_messages()
  end
end
