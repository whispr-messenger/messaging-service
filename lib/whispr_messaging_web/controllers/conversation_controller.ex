defmodule WhisprMessagingWeb.ConversationController do
  @moduledoc """
  Contrôleur pour la gestion des conversations selon la documentation system_design.md
  """
  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.ChatManagement

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Liste toutes les conversations de l'utilisateur authentifié
  """
  def index(conn, _params) do
    user_id = get_current_user_id(conn)
    conversations = Conversations.list_user_conversations(user_id)
    render(conn, :index, conversations: conversations)
  end

  @doc """
  Crée une nouvelle conversation
  """
  def create(conn, %{"conversation" => conversation_params}) do
    user_id = get_current_user_id(conn)
    
    case conversation_params["type"] do
      "direct" ->
        # POST /api/v1/conversations selon 1_chats_management.md section 2.1
        create_direct_conversation(conn, user_id, conversation_params)
        
      "group" ->
        # POST /api/v1/conversations selon 1_chats_management.md section 2.2  
        create_group_conversation(conn, user_id, conversation_params)
        
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, %{errors: %{type: ["must be 'direct' or 'group'"]}})
    end
  end

  @doc """
  Affiche une conversation spécifique
  """
  def show(conn, %{"id" => id}) do
    user_id = get_current_user_id(conn)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(id, user_id) do
      conversation = Conversations.get_conversation_with_members!(id)
      render(conn, :show, conversation: conversation)
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Met à jour une conversation
  """
  def update(conn, %{"id" => id, "conversation" => conversation_params}) do
    user_id = get_current_user_id(conn)
    
    if Conversations.is_member?(id, user_id) do
      conversation = Conversations.get_conversation!(id)
      
      case Conversations.update_conversation(conversation, conversation_params) do
        {:ok, conversation} ->
          render(conn, :show, conversation: conversation)
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Supprime (désactive) une conversation
  """
  def delete(conn, %{"id" => id}) do
    user_id = get_current_user_id(conn)
    
    if Conversations.is_member?(id, user_id) do
      conversation = Conversations.get_conversation!(id)
      
      case Conversations.deactivate_conversation(conversation) do
        {:ok, _conversation} ->
          send_resp(conn, :no_content, "")
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Ajoute un membre à une conversation de groupe
  """
  def add_member(conn, %{"id" => conversation_id, "user_id" => new_user_id}) do
    user_id = get_current_user_id(conn)
    
    if Conversations.is_member?(conversation_id, user_id) do
      case Conversations.add_member_to_conversation(conversation_id, new_user_id) do
        {:ok, _member} ->
          send_resp(conn, :created, "")
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Épingle une conversation selon 1_chats_management.md section 4.1
  """
  def pin(conn, %{"id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.pin_conversation(conversation_id, user_id) do
      {:ok, _member} ->
        send_resp(conn, :ok, "")
        
      {:error, :not_conversation_member} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, %{errors: %{base: ["Access denied"]}})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Désépingle une conversation
  """
  def unpin(conn, %{"id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.unpin_conversation(conversation_id, user_id) do
      {:ok, _member} ->
        send_resp(conn, :ok, "")
        
      {:error, :not_conversation_member} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, %{errors: %{base: ["Access denied"]}})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Archive une conversation selon 1_chats_management.md section 4.2
  """
  def archive(conn, %{"id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.archive_conversation(conversation_id, user_id) do
      {:ok, _member} ->
        send_resp(conn, :ok, "")
        
      {:error, :not_conversation_member} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, %{errors: %{base: ["Access denied"]}})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Désarchive une conversation
  """
  def unarchive(conn, %{"id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.unarchive_conversation(conversation_id, user_id) do
      {:ok, _member} ->
        send_resp(conn, :ok, "")
        
      {:error, :not_conversation_member} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, %{errors: %{base: ["Access denied"]}})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Configure les paramètres d'une conversation selon 1_chats_management.md section 5
  """
  def configure_settings(conn, %{"id" => conversation_id, "settings" => settings_attrs}) do
    user_id = get_current_user_id(conn)
    
    case ChatManagement.configure_conversation_settings(conversation_id, user_id, settings_attrs) do
      {:ok, settings} ->
        render(conn, :settings, settings: settings)
        
      {:error, :not_conversation_member} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, %{errors: %{base: ["Access denied"]}})
        
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:error, changeset: changeset)
    end
  end

  @doc """
  Retire un membre d'une conversation de groupe
  """
  def remove_member(conn, %{"id" => conversation_id, "user_id" => remove_user_id}) do
    user_id = get_current_user_id(conn)
    
    if Conversations.is_member?(conversation_id, user_id) do
      case Conversations.remove_member_from_conversation(conversation_id, remove_user_id) do
        {:ok, _member} ->
          send_resp(conn, :no_content, "")
          
        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> render(:error, %{errors: %{user: ["not found in conversation"]}})
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Marque une conversation comme lue
  """
  def mark_as_read(conn, %{"id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    case Conversations.mark_conversation_as_read(conversation_id, user_id) do
      {:ok, _member} ->
        send_resp(conn, :ok, "")
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, %{errors: %{conversation: ["not found or access denied"]}})
        
      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :error, changeset: changeset)
    end
  end

  @doc """
  Récupère les statistiques de messages non lus
  """
  def unread_stats(conn, _params) do
    user_id = get_current_user_id(conn)
    unread_conversations = Conversations.count_unread_conversations(user_id)
    
    render(conn, :unread_stats, unread_conversations: unread_conversations)
  end

  ## Private Functions

  defp create_direct_conversation(conn, user_id, params) do
    other_user_id = params["other_user_id"]
    metadata = params["metadata"] || %{}
    
    if other_user_id do
      case Conversations.create_direct_conversation(user_id, other_user_id, metadata) do
        {:ok, conversation} ->
          conn
          |> put_status(:created)
          |> render(:show, conversation: conversation)
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:unprocessable_entity)
      |> render(:error, %{errors: %{other_user_id: ["is required for direct conversations"]}})
    end
  end

  defp create_group_conversation(conn, user_id, params) do
    external_group_id = params["external_group_id"]
    metadata = params["metadata"] || %{}
    
    if external_group_id do
      case Conversations.create_group_conversation(external_group_id, user_id, metadata) do
        {:ok, conversation} ->
          conn
          |> put_status(:created)
          |> render(:show, conversation: conversation)
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:unprocessable_entity)
      |> render(:error, %{errors: %{external_group_id: ["is required for group conversations"]}})
    end
  end

  # TODO: Implémenter l'authentification JWT
  defp get_current_user_id(conn) do
    # Pour l'instant, retourner un UUID fixe pour les tests
    # À remplacer par l'extraction du JWT token
    conn.assigns[:current_user_id] || "00000000-0000-0000-0000-000000000001"
  end
end
