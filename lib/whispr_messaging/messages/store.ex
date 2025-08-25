defmodule WhisprMessaging.Messages.Store do
  @moduledoc """
  Module de stockage et récupération des messages selon system_design.md
  Gère la persistance, l'indexation et la récupération optimisée des messages.
  """
  
  require Logger
  
  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Repo
  alias WhisprMessaging.Cache.RedisConnection
  
  import Ecto.Query

  @doc """
  Stocke un message avec indexation pour la recherche
  """
  def store_message(message_attrs) do
    case Messages.create_message(message_attrs) do
      {:ok, message} ->
        # Indexer pour la recherche
        index_message_for_search(message)
        
        # Cache pour accès rapide
        cache_recent_message(message)
        
        {:ok, message}
        
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Récupère les messages d'une conversation avec pagination optimisée
  """
  def get_conversation_messages(conversation_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    before_message_id = Keyword.get(opts, :before_message_id)
    
    query = base_messages_query(conversation_id)
    
    query = 
      if before_message_id do
        where(query, [m], m.id < ^before_message_id)
      else
        query
      end
    
    query
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(^limit)
    |> offset(^offset)
    |> preload([:sender, :attachments, :reactions])
    |> Repo.all()
  end

  @doc """
  Recherche de messages avec indexation full-text
  """
  def search_messages(conversation_id, search_term, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    
    base_messages_query(conversation_id)
    |> where([m], ilike(m.content, ^"%#{search_term}%"))
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> preload([:sender, :attachments])
    |> Repo.all()
  end

  @doc """
  Marque les messages comme expirés selon les politiques de rétention
  """
  def mark_messages_as_expired(conversation_id, cutoff_date) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id 
        and m.inserted_at < ^cutoff_date
        and is_nil(m.expired_at)
    )
    |> Repo.update_all(set: [expired_at: DateTime.utc_now()])
  end

  @doc """
  Compte les messages d'une conversation
  """
  def get_message_count_for_conversation(conversation_id) do
    base_messages_query(conversation_id)
    |> where([m], is_nil(m.expired_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Compte les messages non lus pour un utilisateur
  """
  def get_unread_count_for_user(conversation_id, user_id) do
    # Récupérer le dernier message lu par l'utilisateur
    last_read_query = from(lr in "conversation_members",
      where: lr.conversation_id == ^conversation_id 
        and lr.user_id == ^user_id,
      select: lr.last_read_message_id
    )
    
    last_read_id = Repo.one(last_read_query)
    
    query = base_messages_query(conversation_id)
    
    query = 
      if last_read_id do
        where(query, [m], m.id > ^last_read_id)
      else
        query
      end
    
    query
    |> where([m], is_nil(m.expired_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Statistiques de messages par période
  """
  def count_messages_since(datetime) do
    from(m in Message,
      where: m.inserted_at >= ^datetime,
      select: count(m.id)
    )
    |> Repo.one()
  end

  @doc """
  Taille moyenne des messages
  """
  def get_average_message_size do
    from(m in Message,
      where: not is_nil(m.content),
      select: avg(fragment("LENGTH(?)", m.content))
    )
    |> Repo.one()
    |> case do
      nil -> 0
      avg -> Float.round(avg, 2)
    end
  end

  ## Fonctions privées

  defp base_messages_query(conversation_id) do
    from m in Message,
      where: m.conversation_id == ^conversation_id
  end

  defp index_message_for_search(message) do
    try do
      # Placeholder pour l'indexation de recherche
      # TODO: Implémenter avec Elasticsearch ou PostgreSQL full-text search
      Logger.debug("Indexing message #{message.id} for search")
    rescue
      error ->
        Logger.warning("Failed to index message for search: #{inspect(error)}")
    end
  end

  defp cache_recent_message(message) do
    try do
      # Cache des messages récents pour accès rapide
      key = "recent_messages:#{message.conversation_id}"
      
      RedisConnection.execute_command(:main_pool, "LPUSH", [key, Jason.encode!(message)])
      RedisConnection.execute_command(:main_pool, "LTRIM", [key, "0", "99"])
      RedisConnection.execute_command(:main_pool, "EXPIRE", [key, "3600"])
    rescue
      error ->
        Logger.warning("Failed to cache recent message: #{inspect(error)}")
    end
  end
end
