defmodule WhisprMessaging.Messages.ScheduledMessage do
  @moduledoc """
  Schéma pour les messages programmés selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  
  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scheduled_messages" do
    field :sender_id, :binary_id
    field :message_type, :string
    field :content, :binary
    field :metadata, :map, default: %{}
    field :scheduled_for, :utc_datetime
    field :created_at, :utc_datetime
    field :is_sent, :boolean, default: false
    field :is_cancelled, :boolean, default: false

    belongs_to :conversation, Conversation
  end

  @doc """
  Changeset pour créer ou modifier un message programmé
  """
  def changeset(scheduled_message, attrs) do
    scheduled_message
    |> cast(attrs, [
      :conversation_id, :sender_id, :message_type, :content, 
      :metadata, :scheduled_for, :is_sent, :is_cancelled
    ])
    |> validate_required([:conversation_id, :sender_id, :message_type, :content, :scheduled_for])
    |> validate_inclusion(:message_type, ["text", "media", "system"])
    |> validate_future_scheduled_time()
    |> validate_content_not_empty()
    |> validate_metadata()
    |> put_created_at_if_new()
  end

  @doc """
  Changeset pour créer un nouveau message programmé
  """
  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_change(:created_at, DateTime.utc_now())
    |> put_change(:is_sent, false)
    |> put_change(:is_cancelled, false)
  end

  @doc """
  Changeset pour marquer un message comme envoyé
  """
  def mark_sent_changeset(scheduled_message) do
    scheduled_message
    |> change(is_sent: true)
    |> validate_not_cancelled()
    |> validate_not_already_sent()
  end

  @doc """
  Changeset pour annuler un message programmé
  """
  def cancel_changeset(scheduled_message) do
    scheduled_message
    |> change(is_cancelled: true)
    |> validate_not_already_sent()
  end

  @doc """
  Récupère les messages programmés prêts à être envoyés
  """
  def get_ready_to_send(limit \\ 100) do
    now = DateTime.utc_now()
    
    from(sm in __MODULE__,
      where: not sm.is_sent and 
             not sm.is_cancelled and 
             sm.scheduled_for <= ^now,
      order_by: [asc: sm.scheduled_for],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Récupère les messages programmés d'un utilisateur
  """
  def get_user_scheduled_messages(user_id, include_sent \\ false) do
    query = from(sm in __MODULE__,
      where: sm.sender_id == ^user_id and not sm.is_cancelled,
      order_by: [asc: sm.scheduled_for]
    )
    
    query = if include_sent do
      query
    else
      from(sm in query, where: not sm.is_sent)
    end
    
    Repo.all(query)
  end

  @doc """
  Récupère les messages programmés d'une conversation
  """
  def get_conversation_scheduled_messages(conversation_id, include_sent \\ false) do
    query = from(sm in __MODULE__,
      where: sm.conversation_id == ^conversation_id and not sm.is_cancelled,
      order_by: [asc: sm.scheduled_for]
    )
    
    query = if include_sent do
      query
    else
      from(sm in query, where: not sm.is_sent)
    end
    
    Repo.all(query)
  end

  @doc """
  Nettoie les anciens messages programmés envoyés (plus de 30 jours)
  """
  def cleanup_old_sent_messages do
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30, :day)
    
    from(sm in __MODULE__,
      where: sm.is_sent and sm.created_at < ^thirty_days_ago
    )
    |> Repo.delete_all()
  end

  defp validate_future_scheduled_time(changeset) do
    case get_field(changeset, :scheduled_for) do
      nil -> changeset
      scheduled_time ->
        now = DateTime.utc_now()
        if DateTime.compare(scheduled_time, now) == :gt do
          changeset
        else
          add_error(changeset, :scheduled_for, "must be in the future")
        end
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

  defp put_created_at_if_new(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_not_cancelled(changeset) do
    case get_field(changeset, :is_cancelled) do
      true -> add_error(changeset, :base, "cannot send cancelled message")
      _ -> changeset
    end
  end

  defp validate_not_already_sent(changeset) do
    case get_field(changeset, :is_sent) do
      true -> add_error(changeset, :base, "message already sent")
      _ -> changeset
    end
  end
end
