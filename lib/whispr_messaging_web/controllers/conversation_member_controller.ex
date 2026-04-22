defmodule WhisprMessagingWeb.ConversationMemberController do
  @moduledoc """
  REST API controller for conversation member operations.

  Handles adding, removing, promoting, demoting, and leaving group
  conversations. Enforces admin-only gating, anti-self-lock, anti-self-remove,
  and auto-promote rules (WHISPR-965).
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ConversationMember
  alias WhisprMessagingWeb.Endpoint

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Lists members of a conversation.
  GET /api/v1/conversations/:id/members
  """
  def index(conn, %{"id" => conversation_id}) do
    with {:ok, _conversation} <- Conversations.get_conversation(conversation_id) do
      members = Conversations.list_conversation_members(conversation_id)

      json(conn, %{
        data: Enum.map(members, &render_member/1),
        meta:
          camelize_keys(%{
            conversation_id: conversation_id,
            count: length(members)
          })
      })
    end
  end

  swagger_path :create do
    post("/conversations/{id}/members")
    summary("Add a member to a conversation")
    description("Adds a user to an existing conversation. Requires admin role.")
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
    response(403, "Forbidden - Only admins can add members")
    response(404, "Conversation Not Found")
  end

  @doc """
  Ajoute un membre à une conversation.
  POST /api/v1/conversations/:id/members
  """
  def create(conn, %{"id" => id} = params) do
    member_id = params["user_id"] || params["member_id"]
    current_user_id = conn.assigns[:user_id]

    case Conversations.get_conversation(id) do
      {:ok, conversation} ->
        cond do
          conversation.type == "direct" ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Cannot add members to a direct conversation"})

          not admin?(conversation.id, current_user_id) ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Only admins can add members"})

          true ->
            case Conversations.add_conversation_member(id, member_id) do
              {:ok, member} ->
                broadcast_members_updated(id, "member_added", %{
                  user_id: member.user_id,
                  actor_id: current_user_id
                })

                conn
                |> put_status(:created)
                |> json(%{data: render_member(member)})

              {:error, :not_found} ->
                conn
                |> put_status(:not_found)
                |> json(%{error: "Conversation not found"})

              {:error, reason} ->
                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Failed to add member: #{inspect(reason)}"})
            end
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/conversations/{id}/members/{user_id}")
    summary("Remove a member from a conversation")

    description(
      "Removes a user from a conversation. Requires admin role. Admins cannot " <>
        "remove themselves via this endpoint — use POST /leave."
    )

    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    parameter(:user_id, :path, :string, "UUID of the member to remove", required: true)
    security([%{Bearer: []}])
    response(204, "No Content - Member removed successfully")
    response(400, "Bad Request - Admin cannot remove themselves")
    response(403, "Forbidden - Only admins can remove members")
    response(404, "Member or Conversation Not Found")
  end

  @doc """
  Supprime un membre d'une conversation.
  DELETE /api/v1/conversations/:id/members/:user_id
  """
  def delete(conn, %{"id" => id, "user_id" => member_id}) do
    current_user_id = conn.assigns[:user_id]

    with {:ok, _conversation} <- Conversations.get_conversation(id),
         :ok <- check_not_self_remove(current_user_id, member_id),
         %ConversationMember{} = _member <-
           Conversations.get_conversation_member(id, member_id) ||
             {:error, :member_not_found},
         true <- admin?(id, current_user_id) || {:error, :forbidden},
         {:ok, _} <- Conversations.remove_conversation_member(id, member_id) do
      broadcast_members_updated(id, "member_removed", %{
        user_id: member_id,
        actor_id: current_user_id
      })

      send_resp(conn, :no_content, "")
    else
      {:error, :self_remove} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Cannot remove yourself via DELETE. Use POST /conversations/:id/leave instead."
        })

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Only admins can remove members"})

      {:error, :member_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Member not found"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      error ->
        error
    end
  end

  swagger_path :update_role do
    patch("/conversations/{id}/members/{user_id}/role")
    summary("Promote or demote a conversation member")

    description(
      "Promotes a member to admin or demotes an admin to member. Requires the " <>
        "caller to already be an admin. The only remaining admin cannot demote " <>
        "themselves."
    )

    produces("application/json")
    consumes("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    parameter(:user_id, :path, :string, "UUID of the target member", required: true)

    parameter(
      :role,
      :body,
      Schema.ref(:ConversationMemberRoleRequest),
      "New role",
      required: true
    )

    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:ConversationMemberResponse))
    response(400, "Bad Request - Invalid role or self-demote while only admin")
    response(403, "Forbidden - Only admins can change roles")
    response(404, "Member or Conversation Not Found")
  end

  @doc """
  Change le rôle d'un membre (admin <-> member).
  PATCH /api/v1/conversations/:id/members/:user_id/role
  """
  def update_role(conn, %{"id" => id, "user_id" => target_id} = params) do
    new_role = params["role"]
    current_user_id = conn.assigns[:user_id]

    with {:ok, _conversation} <- Conversations.get_conversation(id),
         true <- new_role in ["admin", "member"] || {:error, :invalid_role},
         %ConversationMember{} = target <-
           Conversations.get_conversation_member(id, target_id) ||
             {:error, :member_not_found},
         true <- admin?(id, current_user_id) || {:error, :forbidden},
         :ok <- check_not_self_lock(id, current_user_id, target_id, new_role),
         {:ok, updated} <- Conversations.set_member_role(target, new_role) do
      broadcast_members_updated(id, "member_role_updated", %{
        user_id: target_id,
        role: new_role,
        actor_id: current_user_id
      })

      json(conn, %{data: render_member(updated)})
    else
      {:error, :invalid_role} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Role must be 'admin' or 'member'"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Only admins can change roles"})

      {:error, :self_lock} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "Cannot demote yourself: you are the only admin",
          hint: "Promote another member to admin first, then retry."
        })

      {:error, :member_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Member not found"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      error ->
        error
    end
  end

  swagger_path :leave do
    post("/conversations/{id}/leave")
    summary("Leave a conversation")

    description(
      "The authenticated user leaves the conversation. If the caller is the " <>
        "last admin, the oldest remaining member is auto-promoted to admin. " <>
        "If the caller is the last member, the conversation is deactivated."
    )

    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "OK")
    response(404, "Conversation Not Found or user is not a member")
  end

  @doc """
  Permet à l'utilisateur authentifié de quitter la conversation.
  POST /api/v1/conversations/:id/leave
  """
  def leave(conn, %{"id" => id}) do
    current_user_id = conn.assigns[:user_id]

    case Conversations.leave_conversation(id, current_user_id) do
      {:ok, result} ->
        broadcast_members_updated(id, "member_left", %{
          user_id: current_user_id,
          auto_promoted_user_id: result.auto_promoted && result.auto_promoted.user_id,
          conversation_deactivated: result.conversation_deactivated
        })

        json(conn, %{
          data:
            camelize_keys(%{
              left: true,
              auto_promoted_user_id: result.auto_promoted && result.auto_promoted.user_id,
              conversation_deactivated: result.conversation_deactivated
            })
        })

      {:error, :not_member} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "You are not a member of this conversation"})

      {:error, :conversation_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Conversation not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Could not leave conversation", reason: inspect(reason)})
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
      ConversationMemberRoleRequest:
        swagger_schema do
          title("Conversation Member Role Request")
          description("Request body for updating a member's role")

          properties do
            role(:string, "New role: 'admin' or 'member'", required: true)
          end
        end,
      ConversationMemberResponse:
        swagger_schema do
          title("Conversation Member Response")
          description("Response containing a conversation member")

          property(
            :data,
            Schema.new do
              properties do
                user_id(:string, "User UUID")
                role(:string, "Member role (admin or member)")
                joined_at(:string, "Join timestamp", format: "date-time")
                is_active(:boolean, "Whether the member is active")
              end
            end,
            "Member object"
          )
        end
    }
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp admin?(_conversation_id, nil), do: false

  defp admin?(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      %ConversationMember{is_active: true} = member ->
        Conversations.member_role(member) == "admin"

      _ ->
        false
    end
  end

  defp check_not_self_remove(user_id, user_id) when not is_nil(user_id),
    do: {:error, :self_remove}

  defp check_not_self_remove(_current, _target), do: :ok

  # Prevent the only active admin from demoting themselves.
  defp check_not_self_lock(conversation_id, current_user_id, target_user_id, "member")
       when current_user_id == target_user_id do
    case Conversations.list_admin_members(conversation_id) do
      [%ConversationMember{user_id: ^current_user_id}] -> {:error, :self_lock}
      _ -> :ok
    end
  end

  defp check_not_self_lock(_conv, _current, _target, _role), do: :ok

  defp broadcast_members_updated(conversation_id, event, payload) do
    Endpoint.broadcast(
      "conversation:#{conversation_id}",
      "conversation_members_updated",
      camelize_keys(Map.merge(payload, %{conversation_id: conversation_id, event: event}))
    )
  end

  defp render_member(member) do
    camelize_keys(%{
      user_id: member.user_id,
      role: Map.get(member.settings || %{}, "role", "member"),
      joined_at: member.joined_at,
      is_active: member.is_active
    })
  end
end
