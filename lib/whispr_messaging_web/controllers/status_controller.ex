defmodule WhisprMessagingWeb.StatusController do
  @moduledoc """
  Controller pour la gestion des statuts de livraison et lecture selon la documentation.
  Gère les statuts de livraison et lecture des messages.
  """
  use WhisprMessagingWeb, :controller

  alias WhisprMessaging.Messages
  alias WhisprMessaging.Messages.Delivery
  alias WhisprMessaging.Security.AuthPlug

  # Authentification requise pour toutes les actions
  plug AuthPlug

  action_fallback WhisprMessagingWeb.FallbackController

  @doc """
  Obtenir le statut de livraison d'un message
  """
  def show(conn, %{"message_id" => message_id}) do
    user_id = get_current_user_id(conn)
    
    case Messages.get_message_delivery_status(message_id) do
      {:ok, delivery_status} ->
        # Filtrer pour ne montrer que les informations autorisées à l'utilisateur
        filtered_status = filter_delivery_status_for_user(delivery_status, user_id)
        
        conn
        |> render(:show, delivery_status: filtered_status)
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Message not found")
    end
  end

  @doc """
  Marquer un message comme lu
  """
  def mark_as_read(conn, %{"message_id" => message_id}) do
    user_id = get_current_user_id(conn)
    
    case Messages.mark_message_as_read(message_id, user_id) do
      {:ok, updated_status} ->
        conn
        |> render(:show, delivery_status: updated_status)
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Message not found")
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Not authorized to mark this message as read")
    end
  end

  @doc """
  Marquer plusieurs messages comme lus
  """
  def mark_multiple_as_read(conn, %{"message_ids" => message_ids}) do
    user_id = get_current_user_id(conn)
    
    results = Enum.map(message_ids, fn message_id ->
      case Messages.mark_message_as_read(message_id, user_id) do
        {:ok, status} -> {:ok, message_id, status}
        {:error, reason} -> {:error, message_id, reason}
      end
    end)
    
    successful = Enum.filter(results, fn {status, _, _} -> status == :ok end)
    failed = Enum.filter(results, fn {status, _, _} -> status == :error end)
    
    conn
    |> render(:bulk_update, 
      successful: successful,
      failed: failed,
      total: length(message_ids)
    )
  end

  @doc """
  Marquer un message comme livré
  """
  def mark_as_delivered(conn, %{"message_id" => message_id}) do
    user_id = get_current_user_id(conn)
    
    case Messages.mark_message_as_delivered(message_id, user_id) do
      {:ok, updated_status} ->
        conn
        |> render(:show, delivery_status: updated_status)
        
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> render(:error, message: "Message not found")
        
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> render(:error, message: "Not authorized to mark this message as delivered")
    end
  end

  @doc """
  Obtenir les statistiques de livraison pour une conversation
  """
  def conversation_stats(conn, %{"conversation_id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
          case Delivery.get_delivery_stats_for_conversation(conversation_id, user_id) do
        {:ok, stats} ->
          conn
          |> render(:conversation_stats, stats: stats)
          
        {:error, :unauthorized} ->
          conn
          |> put_status(:forbidden)
          |> render(:error, message: "Not authorized to view this conversation")
      end
  end

  @doc """
  Obtenir les messages non lus d'une conversation
  """
  def unread_messages(conn, %{"conversation_id" => conversation_id}) do
    user_id = get_current_user_id(conn)
    
    unread_count = Messages.count_unread_messages(conversation_id, user_id)
    
    conn
    |> render(:unread_count, 
      conversation_id: conversation_id,
      unread_count: unread_count
    )
  end

  @doc """
  Obtenir les statistiques globales de livraison pour l'utilisateur
  """
  def user_stats(conn, _params) do
    user_id = get_current_user_id(conn)
    
    stats = %{
      total_messages_sent: get_total_messages_sent(user_id),
      total_messages_received: get_total_messages_received(user_id),
      average_delivery_time: get_average_delivery_time(user_id),
      read_receipts_enabled: get_read_receipts_preference(user_id)
    }
    
    conn
    |> render(:user_stats, stats: stats)
  end

  @doc """
  Mettre à jour les préférences de statuts de l'utilisateur
  """
  def update_preferences(conn, %{"preferences" => preferences}) do
    user_id = get_current_user_id(conn)
    
          case update_user_status_preferences(user_id, preferences) do
        {:ok, updated_preferences} ->
          conn
          |> render(:preferences, preferences: updated_preferences)
      end
  end

  # Fonctions privées

  defp get_current_user_id(conn) do
    # Récupérer l'user_id depuis le token JWT validé par AuthPlug
    case conn.assigns[:user_id] do
      user_id when is_binary(user_id) -> user_id
      _ -> 
        # Cela ne devrait jamais arriver si AuthPlug fonctionne correctement
        raise "User ID not found in connection assigns. Authentication may have failed."
    end
  end

  defp filter_delivery_status_for_user(delivery_status, _user_id) do
    # Filtrer les informations sensibles selon les préférences de confidentialité
    # TODO: Implémenter la logique de filtrage selon les préférences utilisateur
    delivery_status
  end

  defp get_total_messages_sent(_user_id) do
    # TODO: Implémenter le comptage des messages envoyés
    0
  end

  defp get_total_messages_received(_user_id) do
    # TODO: Implémenter le comptage des messages reçus
    0
  end

  defp get_average_delivery_time(_user_id) do
    # TODO: Implémenter le calcul du temps de livraison moyen
    0.0
  end

  defp get_read_receipts_preference(_user_id) do
    # TODO: Implémenter la récupération des préférences utilisateur
    true
  end

  defp update_user_status_preferences(_user_id, preferences) do
    # TODO: Implémenter la mise à jour des préférences
    {:ok, preferences}
  end
end
