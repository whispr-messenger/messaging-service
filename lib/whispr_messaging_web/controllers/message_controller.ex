defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  Controller for managing messages.

  Provides REST API endpoints for message management including
  creating, reading, updating, and deleting messages.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages

  @doc """
  List messages for a conversation.
  """
  def index(conn, %{"id" => conversation_id}) do
    messages = Messages.list_messages(conversation_id)
    json(conn, %{messages: messages})
  end

  @doc """
  Get a specific message by ID.
  """
  def show(conn, %{"id" => id}) do
    case Messages.get_message(id) do
      {:ok, message} ->
        json(conn, message)

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})
    end
  end

  @doc """
  Create a new message in a conversation.
  """
  def create(conn, %{"id" => conversation_id} = params) do
    case Messages.create_message(conversation_id, params) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> json(message)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  Update an existing message.
  """
  def update(conn, %{"id" => id} = params) do
    case Messages.update_message(id, params) do
      {:ok, message} ->
        json(conn, message)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  Delete a message.
  """
  def delete(conn, %{"id" => id}) do
    case Messages.delete_message(id) do
      :ok ->
        json(conn, %{status: "deleted"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end
end
