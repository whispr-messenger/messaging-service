defmodule WhisprMessaging.Workers.SanctionExpiryWorker do
  @moduledoc """
  Periodic worker that deactivates expired conversation sanctions.
  Runs every 60 seconds.
  """

  use GenServer
  require Logger

  alias WhisprMessaging.Moderation.Sanctions

  @interval :timer.seconds(60)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.metadata(domain: :sanction_expiry_worker)
    skip_timer = Keyword.get(opts, :skip_timer, false)
    unless skip_timer, do: schedule_tick()
    {:ok, %{skip_timer: skip_timer}}
  end

  @impl true
  def handle_info(:tick, state) do
    expire_now_impl()
    unless state.skip_timer, do: schedule_tick()
    {:noreply, state}
  end

  @doc """
  Synchronously expire any due sanctions. Used by tests to drive the worker
  deterministically without waiting for the timer.
  """
  def expire_now do
    GenServer.call(__MODULE__, :expire_now)
  end

  @impl true
  def handle_call(:expire_now, _from, state) do
    result = expire_now_impl()
    {:reply, result, state}
  end

  defp expire_now_impl do
    case Sanctions.expire_sanctions() do
      {:ok, count} = ok ->
        if count > 0, do: Logger.info("Sanctions expired", count: count)
        ok

      other ->
        other
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval)
  end
end
