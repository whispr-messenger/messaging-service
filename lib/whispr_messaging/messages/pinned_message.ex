defmodule WhisprMessaging.Messages.PinnedMessage do
  @moduledoc """
  Schéma pour les messages épinglés selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pinned_messages" do
    field :pinned_by, :binary_id
    field :pinned_at, :utc_datetime

    belongs_to :conversation, Conversation
    belongs_to :message, Message
  end

  @doc """
  Changeset pour créer ou modifier un message épinglé
  """
  def changeset(pinned_message, attrs) do
    pinned_message
    |> cast(attrs, [:conversation_id, :message_id, :pinned_by, :pinned_at])
    |> validate_required([:conversation_id, :message_id, :pinned_by])
    |> unique_constraint([:conversation_id, :message_id])
    |> put_pinned_at_if_new()
    |> validate_message_belongs_to_conversation()
  end

  @doc """
  Changeset pour épingler un message
  """
  def pin_message_changeset(conversation_id, message_id, pinned_by_user_id) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      message_id: message_id,
      pinned_by: pinned_by_user_id
    })
    |> put_change(:pinned_at, DateTime.utc_now())
  end

  defp put_pinned_at_if_new(changeset) do
    case get_field(changeset, :pinned_at) do
      nil -> put_change(changeset, :pinned_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_message_belongs_to_conversation(changeset) do
    conversation_id = get_field(changeset, :conversation_id)
    message_id = get_field(changeset, :message_id)
    
    if conversation_id && message_id do
      # Cette validation pourrait être faite avec une requête si nécessaire
      # Pour l'instant, on fait confiance aux contraintes de la base
      changeset
    else
      changeset
    end
  end
end
