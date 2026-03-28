defmodule WhisprMessaging.Workers.ScheduledMessageWorker do
  @moduledoc """
  GenServer that periodically dispatches scheduled messages.

  Polls for pending scheduled messages whose `scheduled_at` timestamp is in
  the past, creates real messages from them, and broadcasts them via
  Phoenix.PubSub so connected clients receive them in real time.

  The poll interval defaults to 60 seconds and is configurable via
  `:whispr_messaging, :scheduled_message_worker, :poll_interval_ms`.
  """

  use GenServer

  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.ScheduledMessage
  alias WhisprMessaging.Repo

  require Logger

  @default_poll_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    dispatch_due_messages()
    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll do
    interval =
      Application.get_env(:whispr_messaging, :scheduled_message_worker, [])
      |> Keyword.get(:poll_interval_ms, @default_poll_interval_ms)

    Process.send_after(self(), :poll, interval)
  end

  # Claim all due messages atomically using SELECT FOR UPDATE SKIP LOCKED.
  # Each replica only processes the rows it could lock; rows already locked
  # by a concurrent worker are skipped, preventing duplicate dispatch.
  defp dispatch_due_messages do
    Repo.transaction(fn ->
      due_messages = Repo.all(ScheduledMessage.claim_due_messages_query())

      Enum.each(due_messages, fn sm ->
        # Mark as processing inside the same transaction to hold the lock
        sm
        |> ScheduledMessage.mark_processing_changeset()
        |> Repo.update!()
      end)

      due_messages
    end)
    |> case do
      {:ok, claimed} ->
        Enum.each(claimed, fn sm ->
          case dispatch_scheduled_message(sm) do
            :ok ->
              Logger.info("Dispatched scheduled message #{sm.id}")

            {:error, reason} ->
              Logger.error("Failed to dispatch scheduled message #{sm.id}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.error("Failed to claim scheduled messages: #{inspect(reason)}")
    end
  end

  defp dispatch_scheduled_message(%ScheduledMessage{} = sm) do
    Repo.transaction(fn ->
      # Re-fetch with a fresh read; idempotency guard — only dispatch if still
      # in processing status (handles the case of a previous partial failure)
      current = Repo.get!(ScheduledMessage, sm.id)

      if current.status == "processing" do
        # Create the actual message
        case Messages.create_message(%{
               conversation_id: sm.conversation_id,
               sender_id: sm.sender_id,
               message_type: sm.message_type,
               content: sm.content,
               metadata: Map.put(sm.metadata, "scheduled_message_id", sm.id),
               client_random: sm.client_random
             }) do
          {:ok, message} ->
            # Mark as sent only after successful message creation
            current
            |> ScheduledMessage.mark_sent_changeset()
            |> Repo.update!()

            # Broadcast to all conversation members via PubSub
            Phoenix.PubSub.broadcast(
              WhisprMessaging.PubSub,
              "conversation:#{sm.conversation_id}",
              {:new_message, message}
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      else
        Logger.warning(
          "Skipping scheduled message #{sm.id} — unexpected status: #{current.status}"
        )
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
