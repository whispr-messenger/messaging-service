defmodule WhisprMessagingWeb.InviteController do
  @moduledoc """
  REST API controller for group invite links (WHISPR-1046).

  Routes:
    * `POST   /messaging/api/v1/conversations/:id/invite_link` — generate (admin)
    * `DELETE /messaging/api/v1/conversations/:id/invite_link` — revoke (admin)
    * `POST   /messaging/api/v1/invites/:token/join` — join as authenticated user
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Invites

  action_fallback WhisprMessagingWeb.FallbackController

  def create(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    with {:ok, conversation} <- Invites.generate_invite(conversation_id, user_id) do
      conn
      |> put_status(:created)
      |> json(%{data: render_invite(conversation)})
    end
  end

  def delete(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    with {:ok, _conversation} <- Invites.revoke_invite(conversation_id, user_id) do
      send_resp(conn, :no_content, "")
    end
  end

  def join(conn, %{"token" => token}) do
    user_id = conn.assigns[:user_id]

    with {:ok, result} <- Invites.join_by_token(token, user_id) do
      status = if result.already_member, do: :ok, else: :created

      conn
      |> put_status(status)
      |> json(%{
        data: %{
          conversationId: result.conversation.id,
          alreadyMember: result.already_member
        }
      })
    end
  end

  defp render_invite(conversation) do
    %{
      token: conversation.invite_token,
      url: Invites.invite_url(conversation.invite_token),
      expiresAt: conversation.invite_expires_at
    }
  end
end
