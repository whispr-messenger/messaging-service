defmodule WhisprMessagingWeb.ReactionController do
  @moduledoc """
  REST API controller for message reaction operations.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages
  alias WhisprMessagingWeb.Endpoint

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Lists reactions for a message.
  GET /api/v1/messages/:id/reactions
  """
  def index(conn, %{"id" => message_id}) do
    with {:ok, _message} <- Messages.get_message(message_id) do
      reactions = Messages.list_message_reactions(message_id)
      summary = Messages.get_reaction_summary(message_id)

      json(conn, %{
        data: Enum.map(reactions, &render_reaction/1),
        meta:
          camelize_keys(%{
            message_id: message_id,
            summary: summary
          })
      })
    end
  end

  @doc """
  Adds a reaction to a message.
  POST /api/v1/messages/:id/reactions

  Body: { "user_id": string, "reaction": string }
  """
  def create(conn, %{"id" => message_id} = params) do
    user_id = params["user_id"] || conn.assigns[:user_id]
    reaction = params["reaction"]

    with {:ok, message} <- Messages.get_message(message_id),
         {:ok, message_reaction} <- Messages.add_reaction(message_id, user_id, reaction) do
      # Diffusion WebSocket sur le topic conversation
      Endpoint.broadcast(
        "conversation:#{message.conversation_id}",
        "reaction_added",
        camelize_keys(%{
          message_id: message_id,
          conversation_id: message.conversation_id,
          user_id: user_id,
          reaction: reaction
        })
      )

      conn
      |> put_status(:created)
      |> json(%{data: render_reaction(message_reaction)})
    end
  end

  @doc """
  Removes a reaction from a message.
  DELETE /api/v1/messages/:id/reactions/:reaction

  Query param: user_id
  """
  def delete(conn, %{"id" => message_id, "reaction" => reaction} = params) do
    user_id = params["user_id"] || conn.assigns[:user_id]

    case Messages.remove_reaction(message_id, user_id, reaction) do
      {:ok, :deleted} ->
        # Récupère conversation_id pour router la diffusion sur le bon topic
        case Messages.get_message(message_id) do
          {:ok, message} ->
            Endpoint.broadcast(
              "conversation:#{message.conversation_id}",
              "reaction_removed",
              camelize_keys(%{
                message_id: message_id,
                conversation_id: message.conversation_id,
                user_id: user_id,
                reaction: reaction
              })
            )

          _ ->
            :ok
        end

        json(conn, %{
          data: camelize_keys(%{message_id: message_id, reaction: reaction, deleted: true})
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Reaction not found"})
    end
  end

  defp render_reaction(reaction) do
    camelize_keys(%{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      reaction: reaction.reaction,
      inserted_at: reaction.inserted_at
    })
  end
end
