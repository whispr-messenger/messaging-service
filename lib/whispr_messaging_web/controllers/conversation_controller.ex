defmodule WhisprMessagingWeb.ConversationController do
  @moduledoc """
  Controller for managing conversations.

  Provides REST API endpoints for conversation management including
  creating, reading, updating, and deleting conversations.
  """

  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations

  @doc """
  List all conversations.
  """
  def index(conn, _params) do
    conversations = Conversations.list_conversations()
    json(conn, %{conversations: conversations})
  end

  @doc """
  Get a specific conversation by ID.
  """
  def show(conn, %{"id" => id}) do
    case Conversations.get_conversation(id) do
      {:ok, conversation} ->
        json(conn, conversation)

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})
    end
  end

  @doc """
  Create a new conversation.
  """
  def create(conn, params) do
    case Conversations.create_conversation(params) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(conversation)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  Update an existing conversation.
  """
  def update(conn, %{"id" => id} = params) do
    case Conversations.update_conversation(id, params) do
      {:ok, conversation} ->
        json(conn, conversation)

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  Delete a conversation.
  """
  def delete(conn, %{"id" => id}) do
    case Conversations.delete_conversation(id) do
      :ok ->
        json(conn, %{status: "deleted"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end
end
