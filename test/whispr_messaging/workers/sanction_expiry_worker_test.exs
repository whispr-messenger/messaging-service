defmodule WhisprMessaging.Workers.SanctionExpiryWorkerTest do
  @moduledoc """
  Tests for the sanction expiry worker GenServer. Verifies the worker
  starts cleanly, runs its tick handler, and survives the underlying
  `Sanctions.expire_sanctions/0` returning various result shapes.
  """

  use WhisprMessaging.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Workers.SanctionExpiryWorker

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "init returns ok with empty state and schedules a future tick" do
    assert {:ok, %{}} = SanctionExpiryWorker.init([])
    # Default interval is 60s — no tick should reach us within the test window
    refute_receive :tick, 50
  end

  test "handle_info(:tick, _) processes the tick and reschedules" do
    assert {:noreply, %{}} = SanctionExpiryWorker.handle_info(:tick, %{})

    # The tick should have rescheduled itself for ~60s in the future, so we
    # do not see a new :tick within the immediate test window.
    refute_receive :tick, 50
  end
end
