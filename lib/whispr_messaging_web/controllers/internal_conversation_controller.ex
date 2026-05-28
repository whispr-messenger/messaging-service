defmodule WhisprMessagingWeb.InternalConversationController do
  @moduledoc """
  Endpoints internes pour interroger l'etat des conversations depuis
  d'autres services (media-service, scheduling-service, etc.).

  Protege par le pipeline :internal_api (header x-internal-token).
  """

  use WhisprMessagingWeb, :controller

  require Logger

  alias WhisprMessaging.Conversations

  @doc """
  Retourne l'etat E2EE d'une conversation.

  GET /messaging/api/v1/internal/conversations/:id/e2ee-status

  Reponse 200 : {"e2ee_enabled": true|false, "conversation_id": "<uuid>"}
  Reponse 404 : {"error": "not_found"}

  Utilise par media-service pour refuser les uploads plaintext sur conv E2EE.
  """
  def e2ee_status(conn, %{"id" => conversation_id}) do
    case Conversations.get_conversation(conversation_id) do
      {:ok, conversation} ->
        json(conn, %{
          conversation_id: conversation.id,
          e2ee_enabled: conversation.e2ee_enabled
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end

  @doc """
  Indique si un user est membre actif d'une conversation.

  GET /messaging/api/v1/internal/conversations/:id/members/:user_id

  Reponse 200 : {"conversation_id": "<uuid>", "user_id": "<uuid>", "is_member": true|false}

  Utilise par media-service pour autoriser le download d'un media attache a
  une conversation par les membres COURANTS (et pas seulement le snapshot
  shared_with fige au moment de l'upload). Un membre qui rejoint un groupe
  apres l'envoi d'un media doit pouvoir le telecharger.
  """
  def member_status(conn, %{"id" => conversation_id, "user_id" => user_id}) do
    is_member = Conversations.user_is_member?(conversation_id, user_id)

    json(conn, %{
      conversation_id: conversation_id,
      user_id: user_id,
      is_member: is_member
    })
  end
end
