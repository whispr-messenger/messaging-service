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

  defp dispatch_due_messages do
    due_messages = Repo.all(ScheduledMessage.due_messages_query())

    Enum.each(due_messages, fn sm ->
      case dispatch_scheduled_message(sm) do
        :ok ->
          Logger.info("Dispatched scheduled message #{sm.id}")

        {:error, reason} ->
          Logger.error("Failed to dispatch scheduled message #{sm.id}: #{inspect(reason)}")
      end
    end)
  end

  defp dispatch_scheduled_message(%ScheduledMessage{} = sm) do
    Repo.transaction(fn ->
      # Mark as sent first to avoid double-dispatch
      case sm
           |> ScheduledMessage.mark_sent_changeset()
           |> Repo.update() do
        {:ok, _updated} ->
          :ok

        {:error, changeset} ->
          Repo.rollback({:mark_sent_failed, changeset})
      end

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
          # Broadcast to all conversation members via PubSub
          Phoenix.PubSub.broadcast(
            WhisprMessaging.PubSub,
            "conversation:#{sm.conversation_id}",
            {:new_message, message}
          )

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
