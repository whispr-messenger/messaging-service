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
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    case Sanctions.expire_sanctions() do
      {:ok, count} when count > 0 ->
        Logger.info("[SanctionExpiryWorker] Expired #{count} sanctions")

      _ ->
        :ok
    end

    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @interval)
  end
end
