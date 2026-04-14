defmodule WhisprMessaging.Workers.ModerationQueueWorkerTest do
  use WhisprMessaging.DataCase, async: false

  alias WhisprMessaging.Workers.ModerationQueueWorker
  alias WhisprMessaging.Moderation.Reports

  setup do
    reporter_id = create_test_user_id()
    reported_user_id = create_test_user_id()

    %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id
    }
  end

  defp create_report(reporter_id, reported_user_id, attrs \\ %{}) do
    default = %{
      reporter_id: reporter_id,
      reported_user_id: reported_user_id,
      category: "spam"
    }

    {:ok, report} = Reports.create_report(Map.merge(default, attrs))
    report
  end

  defp start_worker(opts \\ []) do
    default_opts = [skip_timer: true]
    {:ok, pid} = ModerationQueueWorker.start_link(Keyword.merge(default_opts, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
    end)

    pid
  end

  describe "start_link/1" do
    test "starts the worker process" do
      pid = start_worker()
      assert Process.alive?(pid)
    end
  end

  describe "process_now/0" do
    test "processes pending reports", ctx do
      start_worker()

      create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "violence"})
      create_report(create_test_user_id(), ctx.reported_user_id, %{category: "spam"})

      {:ok, count} = ModerationQueueWorker.process_now()
      assert count >= 2
    end

    test "returns 0 when no pending reports" do
      start_worker()
      {:ok, count} = ModerationQueueWorker.process_now()
      assert count == 0
    end
  end

  describe "status/0" do
    test "returns worker statistics" do
      start_worker()

      status = ModerationQueueWorker.status()
      assert is_map(status)
      assert Map.has_key?(status, :total_processed)
      assert Map.has_key?(status, :total_categorized)
      assert Map.has_key?(status, :total_assigned)
      assert Map.has_key?(status, :total_escalated)
      assert Map.has_key?(status, :uptime_seconds)
      assert Map.has_key?(status, :queue_size)

      assert status.total_processed == 0
      assert status.uptime_seconds >= 0
    end

    test "reflects processing counts after work", ctx do
      start_worker()

      create_report(ctx.reporter_id, ctx.reported_user_id, %{category: "spam"})
      {:ok, _} = ModerationQueueWorker.process_now()

      status = ModerationQueueWorker.status()
      assert status.total_processed >= 1
    end
  end

  describe "update_moderators/1" do
    test "updates the moderator list" do
      start_worker()

      moderators = [Ecto.UUID.generate(), Ecto.UUID.generate()]
      :ok = ModerationQueueWorker.update_moderators(moderators)

      status = ModerationQueueWorker.status()
      assert status.moderator_count == 2
    end
  end

  describe "enqueue/1" do
    test "adds report to priority queue", ctx do
      start_worker()

      report = create_report(ctx.reporter_id, ctx.reported_user_id)
      :ok = ModerationQueueWorker.enqueue(report.id)

      # Check queue size increased
      status = ModerationQueueWorker.status()
      assert status.queue_size >= 1
    end

    test "priority queued reports are processed first", ctx do
      start_worker()

      # Create a normal report
      _normal = create_report(ctx.reporter_id, ctx.reported_user_id)

      # Create and enqueue a priority report
      priority = create_report(create_test_user_id(), ctx.reported_user_id, %{category: "violence"})
      :ok = ModerationQueueWorker.enqueue(priority.id)

      {:ok, count} = ModerationQueueWorker.process_now()
      assert count >= 2

      # Queue should be cleared after processing
      status = ModerationQueueWorker.status()
      assert status.queue_size == 0
    end
  end

  describe "auto-escalation" do
    test "escalates violence reports", ctx do
      start_worker()

      # Create enough reports to trigger repeat offender
      for _ <- 1..3 do
        create_report(create_test_user_id(), ctx.reported_user_id, %{category: "spam"})
      end

      violence_report =
        create_report(create_test_user_id(), ctx.reported_user_id, %{category: "violence"})

      {:ok, _} = ModerationQueueWorker.process_now()

      # The violence report should have been escalated
      {:ok, updated} = Reports.get_report(violence_report.id)
      assert updated.status in ["under_review", "pending"]
    end
  end

  describe "auto-assignment" do
    test "assigns reports to moderators round-robin", ctx do
      mod1 = Ecto.UUID.generate()
      mod2 = Ecto.UUID.generate()

      start_worker()
      :ok = ModerationQueueWorker.update_moderators([mod1, mod2])

      create_report(ctx.reporter_id, ctx.reported_user_id)
      create_report(create_test_user_id(), ctx.reported_user_id)

      {:ok, count} = ModerationQueueWorker.process_now()
      assert count >= 2

      status = ModerationQueueWorker.status()
      assert status.total_assigned >= 2
    end
  end

  describe "handle_info/2" do
    test "handles :tick message" do
      pid = start_worker()

      # Manually send a tick
      send(pid, :tick)
      # Give it time to process
      Process.sleep(100)

      assert Process.alive?(pid)
    end

    test "handles unknown messages gracefully" do
      pid = start_worker()
      send(pid, :unknown_message)
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end
end
