defmodule WhisprMessagingWeb.SanctionController do
  @moduledoc """
  HTTP controller for conversation-level sanctions (mute, kick, shadow_restrict).
  Admin-only endpoints for managing sanctions within conversations.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Moderation.Sanctions

  action_fallback WhisprMessagingWeb.FallbackController

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

  @doc """
  GET /messaging/api/v1/conversations/:conversation_id/sanctions
  Lists active sanctions for a conversation.
  """
  def index(conn, %{"conversation_id" => conversation_id}) do
    sanctions = Sanctions.list_active_sanctions(conversation_id)
    json(conn, %{data: Enum.map(sanctions, &serialize_sanction/1)})
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
