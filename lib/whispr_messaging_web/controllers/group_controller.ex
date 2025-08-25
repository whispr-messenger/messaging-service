defmodule WhisprMessagingWeb.GroupController do
  @moduledoc """
  Controller pour la gestion des groupes de conversation selon la documentation.
  Gère les interactions avec les groupes de conversation.
  """
  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ChatManagement

  @doc """
  Créer un nouveau groupe de conversation
  """
  def create(conn, %{"group" => group_params}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.create_group_conversation(user_id, group_params) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> render(:show, conversation: conversation)
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Ajouter des membres à un groupe
  """
  def add_members(conn, %{"id" => group_id, "members" => member_ids}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.add_group_members(group_id, user_id, member_ids) do
      {:ok, updated_conversation} ->
        conn
        |> render(:show, conversation: updated_conversation)
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Unauthorized to modify this group")
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Group not found")
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Retirer des membres d'un groupe
  """
  def remove_members(conn, %{"id" => group_id, "members" => member_ids}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.remove_group_members(group_id, user_id, member_ids) do
      {:ok, updated_conversation} ->
        conn
        |> render(:show, conversation: updated_conversation)
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Unauthorized to modify this group")
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Group not found")
    end
  end

  @doc """
  Mettre à jour les paramètres d'un groupe
  """
  def update(conn, %{"id" => group_id, "group" => group_params}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.update_group_settings(group_id, user_id, group_params) do
      {:ok, updated_conversation} ->
        conn
        |> render(:show, conversation: updated_conversation)
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Unauthorized to modify this group")
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Group not found")
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Obtenir les informations d'un groupe
  """
  def show(conn, %{"id" => group_id}) do
    _user_id = get_current_user_id(conn)
    
    case Conversations.get_conversation(group_id) do
      {:ok, conversation} ->
        if conversation.type == "group" do
          conn
          |> render(:show, conversation: conversation)
        else
          conn
          |> put_status(:not_found)
          |> render(:error, message: "Group not found")
        end
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Group not found")
    end
  end

  @doc """
  Lister les groupes de l'utilisateur
  """
  def index(conn, _params) do
    user_id = get_current_user_id(conn)
    
    groups = Conversations.list_user_groups(user_id)
    
    conn
    |> render(:index, groups: groups)
  end

  @doc """
  Quitter un groupe
  """
  def leave(conn, %{"id" => group_id}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.leave_group(group_id, user_id) do
      {:ok, _} ->
        conn
        |> put_status(:ok)
        |> render(:success, message: "Successfully left the group")
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Group not found")
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Cannot leave this group")
    end
  end

  # Fonctions privées

  defp get_current_user_id(_conn) do
    # TODO: Implémenter l'extraction de l'user_id depuis le token JWT
    # Pour l'instant, utiliser un user_id de test
    "test_user_id"
  end
end
