defmodule WhisprMessaging.Workers.ScheduledMessageWorker do
  @moduledoc """
  GenServer that periodically dispatches scheduled messages.

  Polls for pending scheduled messages whose `scheduled_at` timestamp is in
  the past, creates real messages from them, and broadcasts them via
  Phoenix Channels so connected clients receive them in real time.

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

  @batch_size 100

  defp dispatch_due_messages do
    dispatch_due_batch()
  end

  defp dispatch_due_batch do
    import Ecto.Query, only: [limit: 2]

    batch =
      ScheduledMessage.due_messages_query()
      |> limit(@batch_size)
      |> Repo.all()

    Enum.each(batch, fn sm ->
      case dispatch_scheduled_message(sm) do
        :ok ->
          Logger.info("Dispatched scheduled message #{sm.id}")

        {:error, reason} ->
          Logger.error("Failed to dispatch scheduled message #{sm.id}: #{inspect(reason)}")
      end
    end)

    if length(batch) == @batch_size, do: dispatch_due_batch()
  end

  defp dispatch_scheduled_message(%ScheduledMessage{} = sm) do
    result =
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
            # Broadcast to all conversation members via Phoenix Channels
            WhisprMessagingWeb.Endpoint.broadcast(
              "conversation:#{sm.conversation_id}",
              "new_message",
              %{message: WhisprMessaging.ConversationServer.serialize_message(message)}
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if permanent_failure?(reason) do
          Logger.warning(
            "Permanent failure for scheduled message #{sm.id}, marking as failed: #{inspect(reason)}"
          )

          sm |> ScheduledMessage.mark_failed_changeset() |> Repo.update()
        end

        {:error, reason}
    end
  end

  # Detect permanent failures that should not be retried.
  # Uniqueness constraint violations (e.g. duplicate client_random) will never
  # succeed on retry and would otherwise cause infinite retry loops.
  defp permanent_failure?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp permanent_failure?({:mark_sent_failed, _}), do: false

  defp permanent_failure?(_reason), do: false
end
