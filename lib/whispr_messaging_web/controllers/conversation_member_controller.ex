defmodule WhisprMessagingWeb.ConversationMemberController do
  @moduledoc """
  REST API controller for conversation member operations.
  Handles adding and removing members from conversations.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :create do
    post("/conversations/{id}/members")
    summary("Add a member to a conversation")
    description("Adds a user to an existing conversation. Requires admin or owner role.")
    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)

    parameter(
      :member,
      :body,
      Schema.ref(:ConversationMemberCreateRequest),
      "Member to add",
      required: true
    )

    security([%{Bearer: []}])
    response(201, "Created", Schema.ref(:ConversationMemberResponse))
    response(403, "Forbidden - User is not an admin or owner of this conversation")
    response(404, "Conversation Not Found")
  end

  @doc """
  Adds one or more members to a conversation.
  POST /api/v1/conversations/:id/members

  Supports both single member (user_id) and batch (user_ids) requests.
  """
  def create(conn, %{"id" => id, "user_ids" => user_ids} = _params) when is_list(user_ids) do
    current_user_id = conn.assigns[:user_id]

    case Conversations.add_conversation_members(id, user_ids, current_user_id) do
      {:ok, members} ->
        conn
        |> put_status(:created)
        |> json(%{data: Enum.map(members, &render_member/1)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to add members"})

      {:error, :not_group} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Batch add is only supported for group conversations"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def create(conn, %{"id" => id} = params) do
    member_id = params["user_id"] || params["member_id"]
    current_user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Conversations.get_conversation(id),
         true <- can_manage_members?(conversation, current_user_id),
         {:ok, member} <- Conversations.add_conversation_member(id, member_id) do
      conn
      |> put_status(:created)
      |> json(%{data: render_member(member)})
    else
      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to add members"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      error ->
        error
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/conversations/{id}/members/{user_id}")
    summary("Remove a member from a conversation")
    description("Removes a user from a conversation. Requires admin or owner role.")
    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    parameter(:user_id, :path, :string, "UUID of the member to remove", required: true)
    security([%{Bearer: []}])
    response(204, "No Content - Member removed successfully")
    response(403, "Forbidden - User is not an admin or owner of this conversation")
    response(404, "Member or Conversation Not Found")
  end

  @doc """
  Supprime un membre d'une conversation.
  DELETE /api/v1/conversations/:id/members/:user_id
  """
  def delete(conn, %{"id" => id, "user_id" => member_id}) do
    current_user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Conversations.get_conversation(id),
         {:member_exists, {:ok, _member}} <-
           {:member_exists,
            Conversations.get_conversation_member(id, member_id)
            |> case do
              nil -> {:error, :not_found}
              member -> {:ok, member}
            end},
         true <- can_manage_members?(conversation, current_user_id),
         {:ok, _} <- Conversations.remove_conversation_member(id, member_id) do
      send_resp(conn, :no_content, "")
    else
      {:member_exists, {:error, :not_found}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Member not found"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Not authorized to remove members"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      error ->
        error
    end
  end

  @doc """
  Updates a member's role in a conversation.
  PATCH /api/v1/conversations/:id/members/:user_id/role

  Body: {"role": "admin"} or {"role": "member"}
  """
  def update_role(conn, %{"id" => id, "user_id" => target_user_id} = params) do
    current_user_id = conn.assigns[:user_id]
    new_role = params["role"]

    if is_nil(new_role) or new_role not in ["admin", "member"] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Invalid role. Must be 'admin' or 'member'"})
    else
      case Conversations.update_member_role(id, target_user_id, new_role, current_user_id) do
        {:ok, updated_member} ->
          json(conn, %{data: render_member(updated_member)})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation or member not found"})

        {:error, :forbidden} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Only admins can change member roles"})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: translate_errors(changeset)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})
      end
    end
  end

  # Swagger Schema Definitions
  def swagger_definitions do
    %{
      ConversationMemberCreateRequest:
        swagger_schema do
          title("Conversation Member Create Request")
          description("Request body for adding a member to a conversation")

          properties do
            user_id(:string, "UUID of the user to add", required: true)
          end
        end,
      ConversationMemberResponse:
        swagger_schema do
          title("Conversation Member Response")
          description("Response containing the newly added conversation member")

          property(
            :data,
            Schema.new do
              properties do
                user_id(:string, "User UUID")
                role(:string, "Member role (e.g. admin, owner, member)")
                joined_at(:string, "Join timestamp", format: "date-time")
                is_active(:boolean, "Whether the member is active")
              end
            end,
            "Member object"
          )
        end
    }
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp can_manage_members?(_conversation, nil), do: false

  defp can_manage_members?(conversation, user_id) do
    case Conversations.get_conversation_member(conversation.id, user_id) do
      %{settings: settings} ->
        role = Map.get(settings || %{}, "role", "member")
        role in ["admin", "owner"]

      _ ->
        false
    end
  end

  defp render_member(member) do
    %{
      user_id: member.user_id,
      role: Map.get(member.settings || %{}, "role", "member"),
      joined_at: member.joined_at,
      is_active: member.is_active
    }
  end
end
