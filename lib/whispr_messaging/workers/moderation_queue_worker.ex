defmodule WhisprMessaging.Workers.ModerationQueueWorker do
  @moduledoc """
  GenServer that processes the moderation report queue asynchronously.

  Responsibilities:
  - Auto-categorize reports based on content keywords
  - Compute and assign priority scores based on severity
  - Auto-assign reports to moderators using round-robin
  - Periodically process pending reports and escalate as needed

  ## Configuration

  Configure via application env under `:whispr_messaging, :moderation_queue`:

      config :whispr_messaging, :moderation_queue,
        process_interval: :timer.seconds(30),
        moderator_ids: ["uuid1", "uuid2"],
        auto_categorize: true,
        auto_assign: true,
        batch_size: 20
  """

  use GenServer

  import Ecto.Query

  alias WhisprMessaging.Repo
  alias WhisprMessaging.Moderation.{Policy, Report}

  require Logger

  @default_interval :timer.seconds(30)
  @default_batch_size 20

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the moderation queue worker.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a processing cycle.
  Returns the number of reports processed.
  """
  @spec process_now() :: {:ok, non_neg_integer()}
  def process_now do
    GenServer.call(__MODULE__, :process_now, :timer.seconds(30))
  end

  @doc """
  Returns the current worker state and statistics.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Updates the list of active moderators for round-robin assignment.
  """
  @spec update_moderators([String.t()]) :: :ok
  def update_moderators(moderator_ids) when is_list(moderator_ids) do
    GenServer.cast(__MODULE__, {:update_moderators, moderator_ids})
  end

  @doc """
  Enqueues a report for priority processing (triggered on report creation).
  """
  @spec enqueue(String.t()) :: :ok
  def enqueue(report_id) when is_binary(report_id) do
    GenServer.cast(__MODULE__, {:enqueue, report_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = load_config()

    interval = Keyword.get(config, :process_interval, @default_interval)
    moderator_ids = Keyword.get(config, :moderator_ids, [])
    auto_categorize = Keyword.get(config, :auto_categorize, true)
    auto_assign = Keyword.get(config, :auto_assign, true)
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    state = %{
      interval: interval,
      moderator_ids: moderator_ids,
      moderator_index: 0,
      auto_categorize: auto_categorize,
      auto_assign: auto_assign,
      batch_size: batch_size,
      total_processed: 0,
      total_categorized: 0,
      total_assigned: 0,
      total_escalated: 0,
      last_run_at: nil,
      priority_queue: [],
      started_at: DateTime.utc_now()
    }

    # Allow disabling via opts for testing
    unless Keyword.get(opts, :skip_timer, false) do
      schedule_tick(interval)
    end

    Logger.info(
      "[ModerationQueueWorker] Started with interval=#{interval}ms, " <>
        "moderators=#{length(moderator_ids)}, batch_size=#{batch_size}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:process_now, _from, state) do
    {count, new_state} = do_process_batch(state)
    {:reply, {:ok, count}, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      total_processed: state.total_processed,
      total_categorized: state.total_categorized,
      total_assigned: state.total_assigned,
      total_escalated: state.total_escalated,
      last_run_at: state.last_run_at,
      moderator_count: length(state.moderator_ids),
      queue_size: length(state.priority_queue),
      uptime_seconds:
        DateTime.diff(DateTime.utc_now(), state.started_at, :second)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:update_moderators, ids}, state) do
    Logger.info("[ModerationQueueWorker] Updated moderators: #{length(ids)} active")
    {:noreply, %{state | moderator_ids: ids, moderator_index: 0}}
  end

  @impl true
  def handle_cast({:enqueue, report_id}, state) do
    # Add to priority queue for next processing cycle
    updated_queue = [report_id | state.priority_queue] |> Enum.uniq()
    {:noreply, %{state | priority_queue: updated_queue}}
  end

  @impl true
  def handle_info(:tick, state) do
    {_count, new_state} = do_process_batch(state)
    schedule_tick(state.interval)
    {:noreply, new_state}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Processing logic
  # ---------------------------------------------------------------------------

  defp do_process_batch(state) do
    Logger.debug("[ModerationQueueWorker] Processing batch (size: #{state.batch_size})")

    # Fetch pending reports, prioritizing any in the priority queue
    reports = fetch_pending_reports(state)

    {processed, categorized, assigned, escalated, new_mod_idx} =
      Enum.reduce(reports, {0, 0, 0, 0, state.moderator_index}, fn report, {p, c, a, e, mod_idx} ->
        # Step 1: Auto-categorize if enabled and description available
        cat_count =
          if state.auto_categorize do
            case auto_categorize_report(report) do
              {:ok, _} -> 1
              _ -> 0
            end
          else
            0
          end

        # Step 2: Compute priority and evaluate policy
        esc_count =
          case evaluate_and_escalate(report) do
            {:escalated, _} -> 1
            _ -> 0
          end

        # Step 3: Auto-assign to moderator if enabled
        {assign_count, next_mod_idx} =
          if state.auto_assign and length(state.moderator_ids) > 0 do
            moderator = Enum.at(state.moderator_ids, rem(mod_idx, length(state.moderator_ids)))
            assign_report(report, moderator)
            {1, mod_idx + 1}
          else
            {0, mod_idx}
          end

        {p + 1, c + cat_count, a + assign_count, e + esc_count, next_mod_idx}
      end)

    new_state = %{
      state
      | total_processed: state.total_processed + processed,
        total_categorized: state.total_categorized + categorized,
        total_assigned: state.total_assigned + assigned,
        total_escalated: state.total_escalated + escalated,
        moderator_index: new_mod_idx,
        last_run_at: DateTime.utc_now(),
        priority_queue: []
    }

    if processed > 0 do
      Logger.info(
        "[ModerationQueueWorker] Processed #{processed} reports " <>
          "(categorized: #{categorized}, assigned: #{assigned}, escalated: #{escalated})"
      )
    end

    {processed, new_state}
  end

  defp fetch_pending_reports(state) do
    # First, fetch any priority-queued reports
    priority_reports =
      if state.priority_queue != [] do
        from(r in Report,
          where: r.id in ^state.priority_queue and r.status == "pending"
        )
        |> Repo.all()
      else
        []
      end

    # Then fill remaining batch capacity from general pending queue
    remaining = state.batch_size - length(priority_reports)
    priority_ids = Enum.map(priority_reports, & &1.id)

    general_reports =
      if remaining > 0 do
        from(r in Report,
          where: r.status == "pending" and r.id not in ^priority_ids,
          order_by: [asc: r.inserted_at],
          limit: ^remaining
        )
        |> Repo.all()
      else
        []
      end

    priority_reports ++ general_reports
  end

  defp auto_categorize_report(%Report{description: nil}), do: {:skip, :no_description}
  defp auto_categorize_report(%Report{description: ""}), do: {:skip, :no_description}

  defp auto_categorize_report(%Report{} = report) do
    case Policy.auto_categorize(report.description) do
      nil ->
        {:skip, :no_match}

      suggested_category when suggested_category != report.category ->
        Logger.debug(
          "[ModerationQueueWorker] Auto-categorized report #{report.id}: " <>
            "#{report.category} -> #{suggested_category}"
        )

        report
        |> Ecto.Changeset.change(%{category: suggested_category})
        |> Repo.update()

      _ ->
        {:skip, :same_category}
    end
  end

  defp evaluate_and_escalate(%Report{} = report) do
    case Policy.evaluate(report) do
      {:ok, %{auto_escalate: true, severity: severity}} ->
        Logger.info(
          "[ModerationQueueWorker] Auto-escalating report #{report.id} (severity: #{severity})"
        )

        report
        |> Ecto.Changeset.change(%{
          auto_escalated: true,
          status: "under_review"
        })
        |> Repo.update()

        {:escalated, severity}

      {:ok, %{priority_score: score}} when score >= 80 ->
        # High priority but not auto-escalate: move to under_review
        report
        |> Ecto.Changeset.change(%{status: "under_review"})
        |> Repo.update()

        {:high_priority, score}

      _ ->
        {:normal, nil}
    end
  end

  defp assign_report(%Report{} = report, moderator_id) do
    # Store assignment in the report's evidence metadata
    updated_evidence =
      Map.merge(report.evidence || %{}, %{
        "assigned_to" => moderator_id,
        "assigned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    report
    |> Ecto.Changeset.change(%{evidence: updated_evidence})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Scheduling
  # ---------------------------------------------------------------------------

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp load_config do
    Application.get_env(:whispr_messaging, :moderation_queue, [])
  end
end
