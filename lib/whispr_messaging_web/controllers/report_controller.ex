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
  # Swagger definitions
  # ---------------------------------------------------------------------------

  def swagger_definitions do
    %{
      Report:
        swagger_schema do
          title("Report")
          description("A moderation report")

          properties do
            id(:string, "Report UUID", format: :uuid)
            reporter_id(:string, "UUID of the user who filed the report", format: :uuid)
            reported_user_id(:string, "UUID of the reported user", format: :uuid)
            conversation_id(:string, "UUID of the conversation", format: :uuid)
            message_id(:string, "UUID of the reported message", format: :uuid)

            category(:string, "Report category",
              enum: [:offensive, :spam, :nudity, :violence, :harassment, :other]
            )

            description(:string, "Free-text description of the issue")
            evidence(:object, "Automatically collected evidence")

            status(:string, "Report status",
              enum: [:pending, :under_review, :resolved_action, :resolved_dismissed]
            )

            resolution(:object, "Resolution details (action taken, notes)")
            auto_escalated(:boolean, "Whether the report was auto-escalated")
            created_at(:string, "Creation timestamp (ISO 8601)", format: :"date-time")
            updated_at(:string, "Last update timestamp (ISO 8601)", format: :"date-time")
          end
        end,
      ReportCreateRequest:
        swagger_schema do
          title("Report Create Request")
          description("Request body for creating a moderation report")

          properties do
            reported_user_id(:string, "UUID of the user being reported",
              required: true,
              format: :uuid
            )

            conversation_id(:string, "UUID of the conversation", format: :uuid)
            message_id(:string, "UUID of the reported message", format: :uuid)

            category(:string, "Report category",
              required: true,
              enum: [:offensive, :spam, :nudity, :violence, :harassment, :other]
            )

            description(:string, "Description of the issue")
          end
        end,
      ReportResolveRequest:
        swagger_schema do
          title("Report Resolve Request")
          description("Request body for resolving a report")

          properties do
            action(:string, "Resolution action taken",
              required: true,
              enum: [:warn, :mute, :kick, :ban, :dismiss]
            )

            notes(:string, "Admin notes about the resolution")
          end
        end,
      ReportResponse:
        swagger_schema do
          title("Report Response")
          description("Single report response")

          properties do
            data(Schema.ref(:Report), "Report object")
            message(:string, "Status message")
          end
        end,
      ReportsListResponse:
        swagger_schema do
          title("Reports List Response")
          description("List of reports")

          properties do
            data(Schema.array(:Report), "Array of report objects")
          end
        end,
      ReportStatsResponse:
        swagger_schema do
          title("Report Stats Response")
          description("Report statistics for admin dashboard")

          properties do
            data(:object, "Statistics object")
          end
        end
    }
  end

  # ---------------------------------------------------------------------------
  # User endpoints
  # ---------------------------------------------------------------------------

  swagger_path :create do
    post("/reports")
    summary("Create a moderation report")
    description("Submits a new moderation report against a user or message. Rate-limited.")
    produces("application/json")
    consumes("application/json")
    tag("Moderation - Reports")

    parameter(:body, :body, Schema.ref(:ReportCreateRequest), "Report parameters", required: true)

    security([%{Bearer: []}])
    response(201, "Report created", Schema.ref(:ReportResponse))
    response(400, "Validation error")
    response(409, "Cooldown active - duplicate report")
    response(429, "Rate limited")
  end

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

  swagger_path :index do
    get("/reports")
    summary("List my reports")
    description("Lists reports submitted by the authenticated user")
    produces("application/json")
    tag("Moderation - Reports")

    parameter(:limit, :query, :integer, "Maximum number of reports (default: 20)",
      required: false
    )

    parameter(:offset, :query, :integer, "Offset for pagination (default: 0)", required: false)

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ReportsListResponse))
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

  swagger_path :show do
    get("/reports/{id}")
    summary("Get report detail")
    description("Returns a single report. Must be the reporter or an admin.")
    produces("application/json")
    tag("Moderation - Reports")

    parameter(:id, :path, :string, "Report UUID", required: true, format: :uuid)

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ReportResponse))
    response(404, "Report not found")
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
        if admin_or_moderator?(conn, user_id) do
          json(conn, %{data: serialize_report(report)})
        else
          conn |> put_status(:forbidden) |> json(%{error: "Access denied"})
        end

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Report not found"})
    end
  end

  # ---------------------------------------------------------------------------
  # Admin endpoints
  # ---------------------------------------------------------------------------

  swagger_path :queue do
    get("/reports/queue")
    summary("Admin report queue")
    description("Lists pending reports for admin review. Filterable by status and category.")
    produces("application/json")
    tag("Moderation - Reports")

    parameter(:limit, :query, :integer, "Maximum number of reports (default: 20)",
      required: false
    )

    parameter(:offset, :query, :integer, "Offset for pagination (default: 0)", required: false)

    parameter(:status, :query, :string, "Filter by status (default: pending)",
      required: false,
      enum: [:pending, :under_review, :resolved_action, :resolved_dismissed]
    )

    parameter(:category, :query, :string, "Filter by category",
      required: false,
      enum: [:offensive, :spam, :nudity, :violence, :harassment, :other]
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ReportsListResponse))
  end

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

  swagger_path :stats do
    get("/reports/stats")
    summary("Report statistics")

    description(
      "Returns report statistics for the admin dashboard (counts by status, category, etc.)"
    )

    produces("application/json")
    tag("Moderation - Reports")

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:ReportStatsResponse))
  end

  @doc """
  GET /messaging/api/v1/reports/stats
  Returns report statistics for admin dashboard.
  """
  def stats(conn, _params) do
    stats = Reports.get_stats()
    json(conn, %{data: stats})
  end

  swagger_path :resolve do
    put("/reports/{id}/resolve")
    summary("Resolve a report")
    description("Resolves a moderation report with an action and optional notes. Admin only.")
    produces("application/json")
    consumes("application/json")
    tag("Moderation - Reports")

    parameter(:id, :path, :string, "Report UUID", required: true, format: :uuid)

    parameter(:body, :body, Schema.ref(:ReportResolveRequest), "Resolution parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(200, "Report resolved", Schema.ref(:ReportResponse))
    response(404, "Report not found")
    response(409, "Report already resolved")
    response(400, "Validation error")
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

  defp admin_or_moderator?(conn, user_id) do
    # If the role was already resolved by the RequireAdmin plug, use it directly
    case conn.assigns[:user_role] do
      role when role in ["admin", "moderator"] ->
        true

      _ ->
        # Resolve inline via the same cache + user-service logic
        alias WhisprMessaging.Cache

        cache_key = "admin_role:#{user_id}"

        case Cache.get(cache_key) do
          {:ok, %{"role" => role}} when role in ["admin", "moderator"] ->
            true

          {:ok, role} when role in ["admin", "moderator"] ->
            true

          _ ->
            resolve_role_from_user_service(conn, user_id, cache_key)
        end
    end
  end

  defp resolve_role_from_user_service(conn, user_id, cache_key) do
    alias WhisprMessaging.Cache

    url =
      (System.get_env("USER_SERVICE_HTTP_URL") || "http://user-service:3002") <>
        "/user/v1/roles/me"

    headers =
      case Plug.Conn.get_req_header(conn, "authorization") do
        [auth | _] -> [{"authorization", auth}, {"accept", "application/json"}]
        _ -> [{"accept", "application/json"}]
      end

    request = Finch.build(:get, url, headers)

    case Finch.request(request, WhisprMessaging.Finch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"role" => role}} ->
            Cache.set(cache_key, %{"role" => role}, 300)
            role in ["admin", "moderator"]

          _ ->
            fallback_admin_check(user_id)
        end

      _ ->
        fallback_admin_check(user_id)
    end
  end

  defp fallback_admin_check(user_id) do
    case System.get_env("ADMIN_USER_IDS") do
      nil -> false
      ids -> user_id in (ids |> String.split(",") |> Enum.map(&String.trim/1))
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
end
