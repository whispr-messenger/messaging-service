defmodule WhisprMessagingWeb.MessageController do
  @moduledoc """
  Contrôleur pour la gestion des messages selon la documentation system_design.md
  """
  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.{Messages, Conversations}
  alias WhisprMessaging.Security.AuthPlug
  # alias WhisprMessaging.Messages.Message (non utilisé actuellement)

  # Authentification requise pour toutes les actions
  plug AuthPlug

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Liste les messages d'une conversation avec pagination
  """
  def index(conn, %{"conversation_id" => conversation_id} = params) do
    user_id = get_current_user_id(conn)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(conversation_id, user_id) do
      opts = [
        limit: Map.get(params, "limit", "50") |> String.to_integer(),
        before: parse_before_timestamp(params["before"])
      ]
      
      messages = Messages.list_conversation_messages(conversation_id, opts)
      render(conn, :index, messages: messages)
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Crée un nouveau message
  """
  def create(conn, %{"conversation_id" => conversation_id, "message" => message_params}) do
    user_id = get_current_user_id(conn)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(conversation_id, user_id) do
      attrs = 
        message_params
        |> Map.put("conversation_id", conversation_id)
        |> Map.put("sender_id", user_id)
        |> Map.put("client_random", generate_client_random())
        |> encode_content_if_needed()
      
      case Messages.create_message(attrs) do
        {:ok, message} ->
          # Broadcaster le message via Phoenix PubSub (à implémenter)
          # broadcast_message_created(message)
          
          conn
          |> put_status(:created)
          |> render(:show, message: message)
          
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
  Affiche un message spécifique
  """
  def show(conn, %{"id" => id}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      render(conn, :show, message: message)
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Met à jour (édite) un message
  """
  def update(conn, %{"id" => id, "message" => message_params}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(id)
    
    # Vérifier que l'utilisateur est l'expéditeur du message
    if message.sender_id == user_id do
      new_content = encode_content(message_params["content"])
      metadata = message_params["metadata"] || %{}
      
      case Messages.update_message(message, new_content, metadata) do
        {:ok, message} ->
          render(conn, :show, message: message)
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Can only edit your own messages"]}})
    end
  end

  @doc """
  Supprime un message
  """
  def delete(conn, %{"id" => id} = params) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(id)
    
    # Vérifier que l'utilisateur est l'expéditeur du message
    if message.sender_id == user_id do
      delete_for_everyone = Map.get(params, "delete_for_everyone", "false") == "true"
      
      case Messages.delete_message(message, delete_for_everyone) do
        {:ok, _message} ->
          send_resp(conn, :no_content, "")
          
        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :error, changeset: changeset)
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Can only delete your own messages"]}})
    end
  end

  @doc """
  Marque un message comme lu
  """
  def mark_as_read(conn, %{"id" => id}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      case Messages.mark_message_as_read(id, user_id) do
        :ok ->
          send_resp(conn, :ok, "")
          
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
  Ajoute une réaction à un message
  """
  def add_reaction(conn, %{"id" => message_id, "reaction" => reaction}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(message_id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      case Messages.add_reaction_to_message(message_id, user_id, reaction) do
        {:ok, _reaction} ->
          send_resp(conn, :created, "")
          
        {:error, :invalid_reaction} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, %{errors: %{reaction: ["is invalid"]}})
          
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
  Retire une réaction d'un message
  """
  def remove_reaction(conn, %{"id" => message_id, "reaction" => reaction}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(message_id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      case Messages.remove_reaction_from_message(message_id, user_id, reaction) do
        :ok ->
          send_resp(conn, :no_content, "")
          
        {:error, :invalid_reaction} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, %{errors: %{reaction: ["is invalid"]}})
      end
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Épingle un message dans une conversation
  """
  def pin(conn, %{"id" => message_id}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(message_id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      case Messages.pin_message(message.conversation_id, message_id, user_id) do
        {:ok, _pinned_message} ->
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
  Désépingle un message
  """
  def unpin(conn, %{"id" => message_id}) do
    user_id = get_current_user_id(conn)
    message = Messages.get_message!(message_id)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(message.conversation_id, user_id) do
      Messages.unpin_message(message.conversation_id, message_id)
      send_resp(conn, :no_content, "")
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  @doc """
  Liste les messages épinglés d'une conversation
  """
  def pinned(conn, %{"conversation_id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    # Vérifier que l'utilisateur est membre de la conversation
    if Conversations.is_member?(conversation_id, user_id) do
      pinned_messages = Messages.list_pinned_messages(conversation_id)
      render(conn, :pinned_messages, pinned_messages: pinned_messages)
    else
      conn
      |> put_status(:forbidden)
      |> render(:error, %{errors: %{base: ["Access denied"]}})
    end
  end

  ## Private Functions

  defp parse_before_timestamp(nil), do: nil
  defp parse_before_timestamp(timestamp_string) do
    case DateTime.from_iso8601(timestamp_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  defp generate_client_random do
    :rand.uniform(1_000_000_000)
  end

  defp encode_content_if_needed(attrs) do
    case attrs["content"] do
      content when is_binary(content) ->
        Map.put(attrs, "content", encode_content(content))
      _ ->
        attrs
    end
  end

  # Pour l'instant, on ne fait que convertir en binaire
  # Dans la vraie implémentation, le contenu arriverait déjà chiffré
  defp encode_content(content) when is_binary(content) do
    content
  end

  defp get_current_user_id(conn) do
    # Récupérer l'user_id depuis le token JWT validé par AuthPlug
    case conn.assigns[:user_id] do
      user_id when is_binary(user_id) -> user_id
      _ -> 
        # Cela ne devrait jamais arriver si AuthPlug fonctionne correctement
        raise "User ID not found in connection assigns. Authentication may have failed."
    end
  end
end
