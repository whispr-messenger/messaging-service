defmodule WhisprMessagingWeb.SanctionController do
  @moduledoc """
  HTTP controller for conversation-level sanctions (mute, kick, shadow_restrict).
  Admin-only endpoints for managing sanctions within conversations.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Moderation.Sanctions

  action_fallback WhisprMessagingWeb.FallbackController

  # ---------------------------------------------------------------------------
  # Swagger definitions
  # ---------------------------------------------------------------------------

  def swagger_definitions do
    %{
      Sanction:
        swagger_schema do
          title("Sanction")
          description("A conversation-level sanction")

          properties do
            id(:string, "Sanction UUID", format: :uuid)
            conversation_id(:string, "Conversation UUID", format: :uuid)
            user_id(:string, "Sanctioned user UUID", format: :uuid)
            type(:string, "Sanction type", enum: [:mute, :kick, :shadow_restrict])
            reason(:string, "Reason for the sanction")
            issued_by(:string, "Admin user UUID who issued the sanction", format: :uuid)

            expires_at(:string, "Expiration timestamp (ISO 8601, null = permanent)",
              format: :"date-time"
            )

            active(:boolean, "Whether the sanction is currently active")
            created_at(:string, "Creation timestamp (ISO 8601)", format: :"date-time")
          end
        end,
      SanctionCreateRequest:
        swagger_schema do
          title("Sanction Create Request")
          description("Request body for creating a conversation sanction")

          properties do
            user_id(:string, "UUID of the user to sanction", required: true, format: :uuid)
            type(:string, "Sanction type", required: true, enum: [:mute, :kick, :shadow_restrict])
            reason(:string, "Reason for the sanction")

            expires_at(:string, "Expiration timestamp (ISO 8601, omit for permanent)",
              format: :"date-time"
            )
          end
        end,
      SanctionResponse:
        swagger_schema do
          title("Sanction Response")
          description("Single sanction response")

          properties do
            data(Schema.ref(:Sanction), "Sanction object")
          end
        end,
      SanctionsListResponse:
        swagger_schema do
          title("Sanctions List Response")
          description("List of sanctions")

          properties do
            data(Schema.array(:Sanction), "Array of sanction objects")
          end
        end
    }
  end

  # ---------------------------------------------------------------------------
  # Endpoints
  # ---------------------------------------------------------------------------

  swagger_path :create do
    post("/conversations/{conversation_id}/sanctions")
    summary("Create a conversation sanction")

    description(
      "Creates a new sanction (mute, kick, or shadow_restrict) on a user in a conversation. Admin only."
    )

    produces("application/json")
    consumes("application/json")
    tag("Moderation - Sanctions")

    parameter(:conversation_id, :path, :string, "Conversation UUID",
      required: true,
      format: :uuid
    )

    parameter(:body, :body, Schema.ref(:SanctionCreateRequest), "Sanction parameters",
      required: true
    )

    security([%{Bearer: []}])
    response(201, "Sanction created", Schema.ref(:SanctionResponse))
    response(400, "Validation error")
  end

  @doc """
  POST /messaging/api/v1/conversations/:conversation_id/sanctions
  Creates a new conversation sanction (admin only).
  """
  def create(conn, %{"conversation_id" => conversation_id} = params) do
    admin_id = conn.assigns[:user_id]

    attrs = %{
      conversation_id: conversation_id,
      user_id: params["user_id"] || params["userId"],
      type: params["type"],
      reason: params["reason"],
      issued_by: admin_id,
      expires_at: parse_expires_at(params["expires_at"] || params["expiresAt"])
    }

    case Sanctions.create_sanction(attrs) do
      {:ok, sanction} ->
        conn
        |> put_status(:created)
        |> json(%{data: serialize_sanction(sanction)})

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: format_errors(changeset)})
    end
  end

  swagger_path :index do
    get("/conversations/{conversation_id}/sanctions")
    summary("List conversation sanctions")
    description("Lists all active sanctions for a given conversation")
    produces("application/json")
    tag("Moderation - Sanctions")

    parameter(:conversation_id, :path, :string, "Conversation UUID",
      required: true,
      format: :uuid
    )

    security([%{Bearer: []}])
    response(200, "Success", Schema.ref(:SanctionsListResponse))
  end

  @doc """
  GET /messaging/api/v1/conversations/:conversation_id/sanctions
  Lists active sanctions for a conversation.
  """
  def index(conn, %{"conversation_id" => conversation_id}) do
    sanctions = Sanctions.list_active_sanctions(conversation_id)
    json(conn, %{data: Enum.map(sanctions, &serialize_sanction/1)})
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/conversations/{conversation_id}/sanctions/{id}")
    summary("Lift a sanction")
    description("Removes/lifts an active sanction. Admin only.")
    produces("application/json")
    tag("Moderation - Sanctions")

    parameter(:conversation_id, :path, :string, "Conversation UUID",
      required: true,
      format: :uuid
    )

    parameter(:id, :path, :string, "Sanction UUID", required: true, format: :uuid)

    security([%{Bearer: []}])
    response(200, "Sanction lifted")
    response(404, "Sanction not found")
    response(409, "Sanction already lifted")
  end

  @doc """
  DELETE /messaging/api/v1/conversations/:conversation_id/sanctions/:id
  Lifts a sanction (admin only).
  """
  def delete(conn, %{"id" => id}) do
    case Sanctions.lift_sanction(id) do
      {:ok, _sanction} ->
        conn |> put_status(:ok) |> json(%{message: "Sanction lifted"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Sanction not found"})

      {:error, :already_lifted} ->
        conn |> put_status(:conflict) |> json(%{error: "Sanction already lifted"})
    end
  end

  defp serialize_sanction(sanction) do
    %{
      id: sanction.id,
      conversation_id: sanction.conversation_id,
      user_id: sanction.user_id,
      type: sanction.type,
      reason: sanction.reason,
      issued_by: sanction.issued_by,
      expires_at: sanction.expires_at && DateTime.to_iso8601(sanction.expires_at),
      active: sanction.active,
      created_at: sanction.inserted_at && NaiveDateTime.to_iso8601(sanction.inserted_at)
    }
  end

  defp parse_expires_at(nil), do: nil

  defp parse_expires_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expires_at(_), do: nil

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_errors(error), do: inspect(error)
end
