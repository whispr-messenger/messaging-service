defmodule WhisprMessagingWeb.DraftController do
  @moduledoc """
  REST API controller for message draft operations.

  Drafts are in-progress messages saved by users before sending.
  Only one draft per user per conversation is allowed (upsert semantics).
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :create do
    post("/messages/drafts")
    summary("Save a message draft")

    description(
      "Saves or updates a draft for a conversation. Only one draft per user per conversation is kept."
    )

    produces("application/json")
    consumes("application/json")

    parameter(:draft, :body, Schema.ref(:DraftCreateRequest), "Draft parameters", required: true)

    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:DraftResponse))
    response(404, "Conversation Not Found")
    response(403, "Forbidden")
  end

  @doc """
  Saves or replaces a draft for the current user in the given conversation.
  POST /api/v1/messages/drafts
  """
  def create(conn, params) do
    user_id = conn.assigns[:user_id]

    draft_params = params["draft"] || Map.drop(params, [])
    conversation_id = draft_params["conversation_id"]
    content = draft_params["content"]
    metadata = draft_params["metadata"] || %{}

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Conversations.conversation_member?(conversation_id, user_id),
           {:ok, draft} <- Messages.upsert_draft(conversation_id, user_id, content, metadata) do
        conn
        |> put_status(:ok)
        |> json(%{data: render_draft(draft)})
      else
        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Conversation not found"})

        false ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Forbidden"})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  swagger_path :show do
    get("/conversations/{id}/drafts")
    summary("Get draft for a conversation")
    description("Retrieves the current user's draft for the given conversation, if any.")
    produces("application/json")
    parameter(:id, :path, :string, "Conversation UUID", required: true)
    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:DraftResponse))
    response(404, "Not Found")
  end

  @doc """
  Gets the draft for the current user in a conversation.
  GET /api/v1/conversations/:id/drafts
  """
  def show(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      case Messages.get_draft(conversation_id, user_id) do
        {:ok, draft} ->
          json(conn, %{data: render_draft(draft)})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No draft found"})
      end
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/messages/drafts/{id}")
    summary("Delete a draft")
    description("Permanently deletes a draft.")
    produces("application/json")
    parameter(:id, :path, :string, "Draft UUID", required: true)
    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:DraftDeleteResponse))
    response(403, "Forbidden")
    response(404, "Not Found")
  end

  @doc """
  Deletes a draft by id.
  DELETE /api/v1/messages/drafts/:id
  """
  def delete(conn, %{"id" => draft_id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      case Messages.delete_draft(draft_id, user_id) do
        {:ok, _draft} ->
          json(conn, %{data: %{id: draft_id, deleted: true}})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Draft not found"})

        {:error, :forbidden} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Forbidden"})
      end
    end
  end

  defp render_draft(draft) do
    %{
      id: draft.id,
      conversation_id: draft.conversation_id,
      user_id: draft.user_id,
      content: draft.content,
      metadata: draft.metadata,
      inserted_at: draft.inserted_at,
      updated_at: draft.updated_at
    }
  end

  def swagger_definitions do
    %{
      DraftCreateRequest:
        swagger_schema do
          title("Draft Create Request")
          description("Request body to save a draft")

          property(
            :draft,
            Schema.new do
              properties do
                conversation_id(:string, "Conversation UUID", required: true)
                content(:string, "Draft content (encrypted)", required: true)
                metadata(:object, "Additional metadata")
              end
            end,
            "Draft parameters"
          )
        end,
      Draft:
        swagger_schema do
          title("Draft")
          description("A message draft object")

          properties do
            id(:string, "Draft UUID")
            conversation_id(:string, "Conversation UUID")
            user_id(:string, "Author UUID")
            content(:string, "Draft content (encrypted)")
            metadata(:object, "Additional metadata")
            inserted_at(:string, "Creation timestamp")
            updated_at(:string, "Last update timestamp")
          end
        end,
      DraftResponse:
        swagger_schema do
          title("Draft Response")
          description("Response containing a draft")

          properties do
            data(Schema.ref(:Draft), "Draft object")
          end
        end,
      DraftDeleteResponse:
        swagger_schema do
          title("Draft Delete Response")
          description("Response after deleting a draft")

          property(
            :data,
            Schema.new do
              properties do
                id(:string, "Draft UUID")
                deleted(:boolean, "Whether the draft was deleted")
              end
            end,
            "Delete result"
          )
        end
    }
  end
end
