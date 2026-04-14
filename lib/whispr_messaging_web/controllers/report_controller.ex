defmodule WhisprMessagingWeb.ReportController do
  @moduledoc """
  HTTP controller for moderation reports.

  Handles report creation (user-facing) and report queue/resolution (admin).
  Matches Imane's frontend reportApi.ts: POST /api/v1/moderation/report
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Moderation.Reports

  action_fallback WhisprMessagingWeb.FallbackController

  # ---------------------------------------------------------------------------
  # User endpoints
  # ---------------------------------------------------------------------------

  @doc """
  POST /messaging/api/v1/reports
  Creates a new report. Also aliased at POST /api/v1/moderation/report
  for compatibility with Imane's frontend.
  """
  def create(conn, params) do
    user_id = conn.assigns[:user_id]

    attrs = %{
      reporter_id: user_id,
      reported_user_id: params["reported_user_id"] || params["reportedUserId"],
      conversation_id: params["conversation_id"] || params["conversationId"],
      message_id: params["message_id"] || params["messageId"],
      category: params["category"],
      description: params["description"]
    }

    case Reports.create_report(attrs) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: serialize_report(report),
          message: "Report submitted successfully"
        })

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many reports. Please wait before submitting another."})

      {:error, :cooldown_active} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "You have already reported this message recently."})

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: format_changeset_errors(changeset)})
    end
  end

  @doc """
  GET /messaging/api/v1/reports
  Lists reports submitted by the authenticated user.
  """
  def index(conn, params) do
    user_id = conn.assigns[:user_id]
    limit = parse_int(params["limit"], 20)
    offset = parse_int(params["offset"], 0)

    reports = Reports.list_my_reports(user_id, limit: limit, offset: offset)

    json(conn, %{data: Enum.map(reports, &serialize_report/1)})
  end

  @doc """
  GET /messaging/api/v1/reports/:id
  Gets a single report (must be reporter or admin).
  """
  def show(conn, %{"id" => id}) do
    user_id = conn.assigns[:user_id]

    case Reports.get_report(id) do
      {:ok, %{reporter_id: ^user_id} = report} ->
        json(conn, %{data: serialize_report(report)})

      {:ok, report} ->
        # TODO: Check admin role when role system is in place
        json(conn, %{data: serialize_report(report)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Report not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Admin endpoints
  # ---------------------------------------------------------------------------

  @doc """
  GET /messaging/api/v1/reports/queue
  Lists pending reports for admin review.
  """
  def queue(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 20),
      offset: parse_int(params["offset"], 0),
      status: params["status"] || "pending",
      category: params["category"]
    ]

    reports = Reports.list_report_queue(opts)
    json(conn, %{data: Enum.map(reports, &serialize_report/1)})
  end

  @doc """
  GET /messaging/api/v1/reports/stats
  Returns report statistics for admin dashboard.
  """
  def stats(conn, _params) do
    stats = Reports.get_stats()
    json(conn, %{data: stats})
  end

  @doc """
  PUT /messaging/api/v1/reports/:id/resolve
  Resolves a report (admin action).
  """
  def resolve(conn, %{"id" => id} = params) do
    admin_id = conn.assigns[:user_id]

    resolution_attrs = %{
      action: params["action"],
      notes: params["notes"]
    }

    case Reports.resolve_report(id, admin_id, resolution_attrs) do
      {:ok, report} ->
        json(conn, %{data: serialize_report(report), message: "Report resolved"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Report not found"})

      {:error, :already_resolved} ->
        conn |> put_status(:conflict) |> json(%{error: "Report already resolved"})

      {:error, changeset} ->
        conn |> put_status(:bad_request) |> json(%{error: format_changeset_errors(changeset)})
    end
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  defp serialize_report(report) do
    %{
      id: report.id,
      reporter_id: report.reporter_id,
      reported_user_id: report.reported_user_id,
      conversation_id: report.conversation_id,
      message_id: report.message_id,
      category: report.category,
      description: report.description,
      evidence: report.evidence,
      status: report.status,
      resolution: report.resolution,
      auto_escalated: report.auto_escalated,
      created_at: report.inserted_at && NaiveDateTime.to_iso8601(report.inserted_at),
      updated_at: report.updated_at && NaiveDateTime.to_iso8601(report.updated_at)
    }
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_changeset_errors(error), do: inspect(error)

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
end
