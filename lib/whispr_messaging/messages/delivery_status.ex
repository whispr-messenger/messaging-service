defmodule WhisprMessaging.Messages.DeliveryStatus do
  @moduledoc """
  Schéma pour les statuts de livraison des messages selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "delivery_statuses" do
    field :user_id, :binary_id
    field :delivered_at, :utc_datetime
    field :read_at, :utc_datetime

    belongs_to :message, Message
  end

  @doc """
  Changeset pour créer ou modifier un statut de livraison
  """
  def changeset(delivery_status, attrs) do
    delivery_status
    |> cast(attrs, [:message_id, :user_id, :delivered_at, :read_at])
    |> validate_required([:message_id, :user_id])
    |> unique_constraint([:message_id, :user_id])
    |> validate_timestamps_order()
  end

  @doc """
  Changeset pour marquer comme livré
  """
  def delivered_changeset(message_id, user_id, delivered_timestamp \\ nil) do
    timestamp = delivered_timestamp || DateTime.utc_now()
    
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      user_id: user_id,
      delivered_at: timestamp
    })
  end

  @doc """
  Changeset pour marquer comme lu
  """
  def read_changeset(delivery_status, read_timestamp \\ nil) do
    timestamp = read_timestamp || DateTime.utc_now()
    
    delivery_status
    |> change(read_at: timestamp)
    |> put_delivered_if_nil(timestamp)
    |> validate_timestamps_order()
  end

  @doc """
  Changeset pour marquer comme lu (avec création si nécessaire)
  """
  def mark_read_changeset(message_id, user_id, read_timestamp \\ nil) do
    timestamp = read_timestamp || DateTime.utc_now()
    
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      user_id: user_id,
      delivered_at: timestamp,  # Si pas encore livré, marquer livré aussi
      read_at: timestamp
    })
  end

  defp put_delivered_if_nil(changeset, read_timestamp) do
    case get_field(changeset, :delivered_at) do
      nil -> put_change(changeset, :delivered_at, read_timestamp)
      _ -> changeset
    end
  end

  defp validate_timestamps_order(changeset) do
    delivered_at = get_field(changeset, :delivered_at)
    read_at = get_field(changeset, :read_at)
    
    cond do
      is_nil(delivered_at) or is_nil(read_at) ->
        changeset
        
      DateTime.compare(read_at, delivered_at) == :lt ->
        add_error(changeset, :read_at, "cannot be before delivered_at")
        
      true ->
        changeset
    end
  end
end
