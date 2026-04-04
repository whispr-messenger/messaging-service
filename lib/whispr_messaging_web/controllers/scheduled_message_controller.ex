defmodule WhisprMessagingWeb.ScheduledMessageController do
  @moduledoc """
  REST API controller for scheduled message operations.

  Allows users to schedule messages for future delivery, list their
  pending scheduled messages, and cancel them before dispatch.
  """

  use WhisprMessagingWeb, :controller
  use PhoenixSwagger

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages

  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  action_fallback WhisprMessagingWeb.FallbackController

  swagger_path :create do
    post("/messages/scheduled")
    summary("Schedule a message")
    description("Schedules a message to be sent at a future time.")
    produces("application/json")
    consumes("application/json")

    parameter(
      :scheduled_message,
      :body,
      Schema.ref(:ScheduledMessageCreateRequest),
      "Scheduled message parameters",
      required: true
    )

    security([%{Bearer: []}])

    response(201, "Created", Schema.ref(:ScheduledMessageResponse))
    response(404, "Conversation Not Found")
    response(403, "Forbidden")
    response(422, "Unprocessable Entity")
  end

  @doc """
  Schedules a message.
  POST /api/v1/messages/scheduled
  """
  def create(conn, params) do
    user_id = conn.assigns[:user_id]

    sm_params = params["scheduled_message"] || Map.drop(params, [])
    conversation_id = sm_params["conversation_id"]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      with {:ok, _conversation} <- Conversations.get_conversation(conversation_id),
           true <- Conversations.conversation_member?(conversation_id, user_id),
           {:ok, scheduled_message} <-
             Messages.schedule_message(
               sm_params
               |> Map.put("sender_id", user_id)
               |> Map.put("conversation_id", conversation_id)
             ) do
        conn
        |> put_status(:created)
        |> json(%{data: render_scheduled_message(scheduled_message)})
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

  swagger_path :index do
    get("/messages/scheduled")
    summary("List scheduled messages")
    description("Lists the current user's pending scheduled messages.")
    produces("application/json")
    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:ScheduledMessagesResponse))
  end

  @doc """
  Lists pending scheduled messages for the current user.
  GET /api/v1/messages/scheduled
  """
  def index(conn, _params) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      messages = Messages.list_scheduled_messages(user_id)

      json(conn, %{
        data: Enum.map(messages, &render_scheduled_message/1),
        meta: %{count: length(messages)}
      })
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/messages/scheduled/{id}")
    summary("Cancel a scheduled message")
    description("Cancels a pending scheduled message before it is dispatched.")
    produces("application/json")
    parameter(:id, :path, :string, "Scheduled message UUID", required: true)
    security([%{Bearer: []}])
    response(200, "OK", Schema.ref(:ScheduledMessageCancelResponse))
    response(403, "Forbidden")
    response(404, "Not Found")
  end

  @doc """
  Cancels a scheduled message.
  DELETE /api/v1/messages/scheduled/:id
  """
  def delete(conn, %{"id" => id}) do
    user_id = conn.assigns[:user_id]

    if is_nil(user_id) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized"})
    else
      case Messages.cancel_scheduled_message(id, user_id) do
        {:ok, sm} ->
          json(conn, %{data: render_scheduled_message(sm)})

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Scheduled message not found"})

        {:error, :forbidden} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Forbidden"})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  defp render_scheduled_message(sm) do
    camelize_keys(%{
      id: sm.id,
      conversation_id: sm.conversation_id,
      sender_id: sm.sender_id,
      message_type: sm.message_type,
      content: sm.content,
      metadata: sm.metadata,
      scheduled_at: sm.scheduled_at,
      status: sm.status,
      inserted_at: sm.inserted_at,
      updated_at: sm.updated_at
    })
  end

  def swagger_definitions do
    %{
      ScheduledMessageCreateRequest:
        swagger_schema do
          title("Scheduled Message Create Request")
          description("Request body to schedule a message")

          property(
            :scheduled_message,
            Schema.new do
              properties do
                conversation_id(:string, "Conversation UUID", required: true)
                content(:string, "Message content (encrypted)", required: true)
                message_type(:string, "Message type (text or media)")
                scheduled_at(:string, "ISO 8601 datetime for dispatch", required: true)
                client_random(:integer, "Client deduplication token", required: true)
                metadata(:object, "Additional metadata")
              end
            end,
            "Scheduled message parameters"
          )
        end,
      ScheduledMessage:
        swagger_schema do
          title("ScheduledMessage")
          description("A scheduled message object")

          properties do
            id(:string, "UUID")
            conversation_id(:string, "Conversation UUID")
            sender_id(:string, "Sender UUID")
            message_type(:string, "Message type")
            content(:string, "Encrypted content")
            metadata(:object, "Additional metadata")
            scheduled_at(:string, "Dispatch timestamp")
            status(:string, "Status: pending | sent | cancelled")
            inserted_at(:string, "Creation timestamp")
            updated_at(:string, "Last update timestamp")
          end
        end,
      ScheduledMessageResponse:
        swagger_schema do
          title("Scheduled Message Response")
          description("Response containing a scheduled message")

          properties do
            data(Schema.ref(:ScheduledMessage), "Scheduled message")
          end
        end,
      ScheduledMessagesResponse:
        swagger_schema do
          title("Scheduled Messages Response")
          description("Response containing a list of scheduled messages")

          properties do
            data(Schema.array(:ScheduledMessage), "List of scheduled messages")
          end

          property(
            :meta,
            Schema.new do
              properties do
                count(:integer, "Number of items")
              end
            end,
            "Pagination metadata"
          )
        end,
      ScheduledMessageCancelResponse:
        swagger_schema do
          title("Scheduled Message Cancel Response")
          description("Response after cancelling a scheduled message")

          properties do
            data(Schema.ref(:ScheduledMessage), "Cancelled scheduled message")
          end
        end
    }
  end
end
