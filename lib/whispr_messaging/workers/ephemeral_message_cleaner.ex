defmodule WhisprMessaging.Workers.EphemeralMessageCleaner do
  @moduledoc """
  Background worker that periodically deletes expired ephemeral messages.

  Runs on a configurable interval (default: 60 seconds) and hard-deletes
  any messages whose `expires_at` timestamp is in the past. Broadcasts a
  `message:expired` event over the conversation channel so connected clients
  can remove the message from their UI in real time.
  """

  use GenServer

  import Ecto.Query, warn: false

  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Repo

  require Logger

  # Default cleanup interval: 60 seconds
  @default_interval_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Logger.metadata(domain: :ephemeral_message_cleaner)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    skip_timer = Keyword.get(opts, :skip_timer, false)
    unless skip_timer, do: schedule_cleanup(interval)
    {:ok, %{interval_ms: interval, skip_timer: skip_timer}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    deleted_count = delete_expired_messages()

    if deleted_count > 0 do
      Logger.info("Expired messages deleted", count: deleted_count)
    end

    unless state.skip_timer, do: schedule_cleanup(state.interval_ms)
    {:noreply, state}
  end

  @doc """
  Synchronously delete all currently expired messages. Used by tests to drive
  the worker deterministically without waiting for the timer.
  """
  def cleanup_now do
    GenServer.call(__MODULE__, :cleanup_now)
  end

  @impl true
  def handle_call(:cleanup_now, _from, state) do
    deleted_count = delete_expired_messages()
    {:reply, {:ok, deleted_count}, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp delete_expired_messages do
    now = DateTime.utc_now()

    # Fetch expired messages (need conversation_id for broadcast)
    expired =
      from(m in Message,
        where: not is_nil(m.expires_at) and m.expires_at <= ^now and m.is_deleted == false,
        select: %{id: m.id, conversation_id: m.conversation_id}
      )
      |> Repo.all()

    if Enum.empty?(expired) do
      0
    else
      ids = Enum.map(expired, & &1.id)

      {deleted_count, _} =
        from(m in Message, where: m.id in ^ids)
        |> Repo.delete_all()

      # Notify each conversation's channel about the removed messages
      Enum.each(expired, fn %{id: message_id, conversation_id: conversation_id} ->
        WhisprMessagingWeb.Endpoint.broadcast(
          "conversation:#{conversation_id}",
          "message:expired",
          %{message_id: message_id, conversation_id: conversation_id}
        )
      end)

      deleted_count
    end
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
