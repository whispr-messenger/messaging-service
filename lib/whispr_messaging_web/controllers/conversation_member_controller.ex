defmodule WhisprMessagingWeb.ConversationMemberController do
  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations

  @doc """
  Ajoute un membre à une conversation.
  POST /api/v1/conversations/:id/members
  """
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

      error ->
        error
    end
  end

  @doc """
  Supprime un membre d'une conversation.
  DELETE /api/v1/conversations/:id/members/:user_id
  """
  def delete(conn, %{"id" => id, "user_id" => member_id} = params) do
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

  # Fonctions utilitaires
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
