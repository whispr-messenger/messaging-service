defmodule WhisprMessaging.Conversations.ConversationMember do
  @moduledoc """
  Schéma pour les membres de conversation selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_members" do
    field :user_id, :binary_id
    field :settings, :map, default: %{}
    field :joined_at, :utc_datetime
    field :last_read_at, :utc_datetime
    field :is_active, :boolean, default: true

    belongs_to :conversation, Conversation
  end

  @doc """
  Changeset pour créer ou modifier un membre de conversation
  """
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:conversation_id, :user_id, :settings, :joined_at, :last_read_at, :is_active])
    |> validate_required([:conversation_id, :user_id])
    |> unique_constraint([:conversation_id, :user_id])
    |> put_joined_at_if_new()
    |> validate_settings()
  end

  @doc """
  Changeset pour ajouter un nouveau membre
  """
  def add_member_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_change(:joined_at, DateTime.utc_now())
    |> put_change(:is_active, true)
  end

  @doc """
  Marquer un message comme lu pour ce membre
  """
  def mark_read_changeset(member, read_timestamp \\ nil) do
    timestamp = read_timestamp || DateTime.utc_now()
    
    member
    |> change(last_read_at: timestamp)
  end

  @doc """
  Désactiver un membre (le retirer de la conversation)
  """
  def deactivate_changeset(member) do
    member
    |> change(is_active: false)
  end

  defp put_joined_at_if_new(changeset) do
    case get_field(changeset, :joined_at) do
      nil -> put_change(changeset, :joined_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp validate_settings(changeset) do
    case get_field(changeset, :settings) do
      settings when is_map(settings) -> changeset
      _ -> add_error(changeset, :settings, "must be a valid map")
    end
  end
end
