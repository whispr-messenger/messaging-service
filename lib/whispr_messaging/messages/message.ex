defmodule WhisprMessaging.Messages.Message do
  @moduledoc """
  Schéma pour les messages selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  
  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.{DeliveryStatus, MessageReaction, MessageAttachment}
  alias WhisprMessaging.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :sender_id, :binary_id
    field :message_type, :string
    field :content, :binary
    field :metadata, :map, default: %{}
    field :client_random, :integer
    field :sent_at, :utc_datetime
    field :edited_at, :utc_datetime
    field :is_deleted, :boolean, default: false
    field :delete_for_everyone, :boolean, default: false

    belongs_to :conversation, Conversation
    belongs_to :reply_to, __MODULE__
    has_many :delivery_statuses, DeliveryStatus
    has_many :reactions, MessageReaction
    has_many :attachments, MessageAttachment

    timestamps()
  end

  @doc """
  Changeset pour créer ou modifier un message
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id, :sender_id, :reply_to_id, :message_type, 
      :content, :metadata, :client_random, :sent_at, :edited_at
    ])
    |> validate_required([:conversation_id, :sender_id, :message_type, :content, :client_random])
    |> validate_inclusion(:message_type, ["text", "media", "system"])
    |> unique_constraint([:sender_id, :client_random])
    |> put_sent_at_if_new()
    |> validate_content_not_empty()
    |> validate_metadata()
  end

  @doc """
  Changeset pour créer un nouveau message
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_change(:sent_at, DateTime.utc_now())
  end

  @doc """
  Changeset pour éditer un message existant
  """
  def edit_changeset(message, new_content, metadata \\ %{}) do
    message
    |> change(content: new_content, metadata: metadata, edited_at: DateTime.utc_now())
    |> validate_not_deleted()
  end

  @doc """
  Changeset pour supprimer un message
  """
  def delete_changeset(message, delete_for_everyone \\ false) do
    message
    |> change(
      is_deleted: true, 
      delete_for_everyone: delete_for_everyone,
      edited_at: DateTime.utc_now()
    )
  end

  @doc """
  Récupère les messages récents d'une conversation avec pagination
  """
  def get_recent_messages(conversation_id, limit \\ 50, before_timestamp \\ nil) do
    query = from m in __MODULE__,
      where: m.conversation_id == ^conversation_id and not m.is_deleted,
      order_by: [desc: m.sent_at],
      limit: ^limit,
      preload: [:reactions, :attachments]
      
    query = if before_timestamp do
      from m in query, where: m.sent_at < ^before_timestamp
    else
      query
    end
    
    Repo.all(query)
    |> Enum.reverse()  # Pour avoir l'ordre chronologique
  end

  @doc """
  Marque comme lu pour un utilisateur
  """
  def mark_as_read(message_id, user_id) do
    now = DateTime.utc_now()
    
    # Mettre à jour ou créer le statut de livraison
    %DeliveryStatus{
      message_id: message_id,
      user_id: user_id,
      read_at: now
    }
    |> Repo.insert(
      on_conflict: [set: [read_at: now]],
      conflict_target: [:message_id, :user_id]
    )
    
    # Mettre à jour la dernière lecture de la conversation
    message = Repo.get!(__MODULE__, message_id)
    
    from(cm in WhisprMessaging.Conversations.ConversationMember,
      where: cm.conversation_id == ^message.conversation_id and 
             cm.user_id == ^user_id)
    |> Repo.update_all(set: [last_read_at: now])
    
    :ok
  end

  @doc """
  Compte les messages non lus dans une conversation pour un utilisateur
  """
  def count_unread_messages(conversation_id, user_id) do
    # Récupérer le dernier timestamp de lecture
    last_read = from(cm in WhisprMessaging.Conversations.ConversationMember,
      where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id,
      select: cm.last_read_at
    ) |> Repo.one()

    case last_read do
      nil ->
        # Si jamais lu, tout est non lu
        from(m in __MODULE__,
          where: m.conversation_id == ^conversation_id and 
                 m.sender_id != ^user_id and 
                 not m.is_deleted,
          select: count()
        ) |> Repo.one()
        
      last_read_at ->
        # Compter les messages depuis la dernière lecture
        from(m in __MODULE__,
          where: m.conversation_id == ^conversation_id and 
                 m.sender_id != ^user_id and 
                 m.sent_at > ^last_read_at and 
                 not m.is_deleted,
          select: count()
        ) |> Repo.one()
    end
  end

  defp put_sent_at_if_new(changeset) do
    case get_field(changeset, :sent_at) do
      nil -> put_change(changeset, :sent_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_content_not_empty(changeset) do
    case get_field(changeset, :content) do
      content when is_binary(content) and byte_size(content) > 0 -> changeset
      _ -> add_error(changeset, :content, "cannot be empty")
    end
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      metadata when is_map(metadata) -> changeset
      _ -> add_error(changeset, :metadata, "must be a valid map")
    end
  end

  defp validate_not_deleted(changeset) do
    case get_field(changeset, :is_deleted) do
      true -> add_error(changeset, :base, "cannot edit deleted message")
      _ -> changeset
    end
  end
end
