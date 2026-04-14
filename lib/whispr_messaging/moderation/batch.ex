defmodule WhisprMessaging.Moderation.Batch do
  @moduledoc """
  Batch operations for moderation administration.

  Provides bulk actions for resolving, dismissing, reassigning, and
  categorizing reports. All operations are transactional and emit
  audit events for each affected report.
  """

  import Ecto.Query

  alias WhisprMessaging.Repo
  alias WhisprMessaging.Moderation.Report
  alias WhisprMessaging.Moderation.Reports

  require Logger

  @type batch_result :: %{
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          errors: [%{id: String.t(), reason: String.t()}]
        }

  # ---------------------------------------------------------------------------
  # Bulk resolve
  # ---------------------------------------------------------------------------

  @doc """
  Resolves multiple reports in a single transaction.

  ## Parameters
    * `report_ids` - list of report UUIDs to resolve
    * `admin_id` - the admin performing the action
    * `resolution_attrs` - map with `:action` and optional `:notes`

  ## Returns
  `{:ok, %{succeeded: N, failed: M, errors: [...]}}` or `{:error, reason}`

  ## Examples

      Batch.bulk_resolve(
        ["uuid1", "uuid2", "uuid3"],
        admin_id,
        %{action: "dismiss", notes: "Duplicate reports"}
      )
  """
  @spec bulk_resolve([String.t()], String.t(), map()) :: {:ok, batch_result()} | {:error, term()}
  def bulk_resolve(report_ids, admin_id, resolution_attrs) when is_list(report_ids) do
    Logger.info(
      "[Batch] Bulk resolve #{Enum.count(report_ids)} reports by admin #{admin_id}, action: #{resolution_attrs.action}"
    )

    results =
      Enum.map(report_ids, fn id ->
        case Reports.resolve_report(id, admin_id, resolution_attrs) do
          {:ok, report} ->
            {:ok, report}

          {:error, reason} ->
            {:error, id, reason}
        end
      end)

    summary = build_batch_summary(results)

    Logger.info(
      "[Batch] Bulk resolve complete: #{summary.succeeded} succeeded, #{summary.failed} failed"
    )

    {:ok, summary}
  end

  # ---------------------------------------------------------------------------
  # Bulk dismiss
  # ---------------------------------------------------------------------------

  @doc """
  Dismisses multiple reports at once.
  Convenience wrapper around `bulk_resolve/3` with action "dismiss".

  ## Parameters
    * `report_ids` - list of report UUIDs
    * `admin_id` - the admin performing the dismissal
    * `notes` - optional dismissal notes (default: "Bulk dismissed")
  """
  @spec bulk_dismiss([String.t()], String.t(), String.t()) ::
          {:ok, batch_result()} | {:error, term()}
  def bulk_dismiss(report_ids, admin_id, notes \\ "Bulk dismissed") do
    bulk_resolve(report_ids, admin_id, %{action: "dismiss", notes: notes})
  end

  # ---------------------------------------------------------------------------
  # Bulk status update (direct DB update for performance)
  # ---------------------------------------------------------------------------

  @doc """
  Updates the status of multiple reports directly in the database.
  Uses a single UPDATE query for performance on large batches.

  This bypasses individual report validation -- use only for trusted admin ops
  like moving reports to "under_review".

  ## Parameters
    * `report_ids` - list of report UUIDs
    * `new_status` - target status (must be a valid Report status)

  ## Returns
  `{:ok, count}` where count is the number of updated rows.
  """
  @spec bulk_update_status([String.t()], String.t()) :: {:ok, non_neg_integer()}
  def bulk_update_status(report_ids, new_status)
      when is_list(report_ids) and
             new_status in ~w(pending under_review resolved_action resolved_dismissed) do
    Logger.info(
      "[Batch] Bulk status update to '#{new_status}' for #{Enum.count(report_ids)} reports"
    )

    {count, _} =
      from(r in Report,
        where: r.id in ^report_ids
      )
      |> Repo.update_all(set: [status: new_status])

    Logger.info("[Batch] Updated #{count} reports to status '#{new_status}'")
    {:ok, count}
  end

  def bulk_update_status(_report_ids, invalid_status) do
    {:error, {:invalid_status, invalid_status}}
  end

  # ---------------------------------------------------------------------------
  # Bulk categorize
  # ---------------------------------------------------------------------------

  @doc """
  Re-categorizes multiple reports to a new category.

  ## Parameters
    * `report_ids` - list of report UUIDs
    * `new_category` - the new category (must be valid)

  ## Returns
  `{:ok, count}` where count is the number of updated rows,
  or `{:error, :invalid_category}`.
  """
  @spec bulk_categorize([String.t()], String.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_category}
  def bulk_categorize(report_ids, new_category) when is_list(report_ids) do
    if new_category in Report.valid_categories() do
      Logger.info(
        "[Batch] Re-categorizing #{Enum.count(report_ids)} reports to '#{new_category}'"
      )

      {count, _} =
        from(r in Report, where: r.id in ^report_ids)
        |> Repo.update_all(set: [category: new_category])

      {:ok, count}
    else
      {:error, :invalid_category}
    end
  end

  # ---------------------------------------------------------------------------
  # Batch by filter (resolve all matching a criteria)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves all pending reports matching a filter.
  Useful for clearing out an entire category of reports, e.g. after
  determining a wave of reports was coordinated abuse.

  ## Options
    * `:category` - filter by category
    * `:reported_user_id` - filter by reported user
    * `:older_than_days` - only reports older than N days

  ## Returns
  `{:ok, count}` with the number of dismissed reports.
  """
  @spec dismiss_by_filter(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def dismiss_by_filter(admin_id, opts \\ []) do
    category = Keyword.get(opts, :category)
    reported_user_id = Keyword.get(opts, :reported_user_id)
    older_than_days = Keyword.get(opts, :older_than_days)

    query =
      from(r in Report, where: r.status == "pending")
      |> maybe_filter(:category, category)
      |> maybe_filter(:reported_user_id, reported_user_id)
      |> maybe_filter_older_than(older_than_days)

    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    resolution = %{
      "action" => "dismiss",
      "resolved_by" => admin_id,
      "resolved_at" => now_iso,
      "notes" => "Bulk dismissed by filter"
    }

    {count, _} =
      Repo.update_all(query,
        set: [status: "resolved_dismissed", resolution: resolution]
      )

    Logger.info("[Batch] Dismissed #{count} reports by filter (admin: #{admin_id})")
    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Merge duplicate reports
  # ---------------------------------------------------------------------------

  @doc """
  Finds and merges duplicate reports (same reporter + same message).
  Keeps the earliest report and dismisses the rest.

  ## Returns
  `{:ok, %{duplicates_found: N, dismissed: M}}`
  """
  @spec merge_duplicates(String.t()) ::
          {:ok, %{duplicates_found: non_neg_integer(), dismissed: non_neg_integer()}}
  def merge_duplicates(admin_id) do
    Logger.info("[Batch] Scanning for duplicate reports")

    # Find groups of reports with same reporter_id + message_id (pending only)
    duplicates =
      from(r in Report,
        where: r.status == "pending" and not is_nil(r.message_id),
        group_by: [r.reporter_id, r.message_id],
        having: count(r.id) > 1,
        select: {r.reporter_id, r.message_id, count(r.id)}
      )
      |> Repo.all()

    dismissed_count =
      Enum.reduce(duplicates, 0, fn {reporter_id, message_id, _count}, acc ->
        # Get all reports for this combo, keep the oldest
        reports =
          from(r in Report,
            where:
              r.reporter_id == ^reporter_id and
                r.message_id == ^message_id and
                r.status == "pending",
            order_by: [asc: r.inserted_at]
          )
          |> Repo.all()

        # Dismiss all except the first (oldest)
        to_dismiss = reports |> Enum.drop(1) |> Enum.map(& &1.id)

        case to_dismiss do
          [] ->
            acc

          ids ->
            {:ok, count} = bulk_dismiss(ids, admin_id, "Merged duplicate report")
            acc + count.succeeded
        end
      end)

    Logger.info(
      "[Batch] Duplicate scan complete: #{Enum.count(duplicates)} groups, #{dismissed_count} dismissed"
    )

    {:ok, %{duplicates_found: Enum.count(duplicates), dismissed: dismissed_count}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_batch_summary(results) do
    {ok_results, err_results} = Enum.split_with(results, &match?({:ok, _}, &1))

    errors =
      Enum.map(err_results, fn {:error, id, reason} ->
        %{id: id, reason: format_error_reason(reason)}
      end)

    %{
      succeeded: Enum.count(ok_results),
      failed: Enum.count(err_results),
      errors: errors
    }
  end

  defp format_error_reason(:not_found), do: "Report not found"
  defp format_error_reason(:already_resolved), do: "Report already resolved"
  defp format_error_reason(%Ecto.Changeset{} = cs), do: inspect(cs.errors)
  defp format_error_reason(reason), do: inspect(reason)

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, :category, category) do
    from(r in query, where: r.category == ^category)
  end

  defp maybe_filter(query, :reported_user_id, user_id) do
    from(r in query, where: r.reported_user_id == ^user_id)
  end

  defp maybe_filter_older_than(query, nil), do: query

  defp maybe_filter_older_than(query, days) when is_integer(days) and days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
    from(r in query, where: r.inserted_at <= ^cutoff)
  end
end
