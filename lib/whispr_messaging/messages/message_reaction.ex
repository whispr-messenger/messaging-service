defmodule WhisprMessaging.Messages.MessageReaction do
  @moduledoc """
  Schéma pour les réactions aux messages selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reactions" do
    field :user_id, :binary_id
    field :reaction, :string
    field :created_at, :utc_datetime

    belongs_to :message, Message
  end

  @valid_reactions [
    "👍", "👎", "❤️", "😂", "😮", "😢", "😡",
    "+1", "-1", "heart", "laugh", "wow", "sad", "angry"
  ]

  @doc """
  Changeset pour créer ou modifier une réaction
  """
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :reaction])
    |> validate_required([:message_id, :user_id, :reaction])
    |> validate_inclusion(:reaction, @valid_reactions)
    |> unique_constraint([:message_id, :user_id, :reaction])
    |> put_created_at_if_new()
  end

  @doc """
  Changeset pour ajouter une nouvelle réaction
  """
  def add_reaction_changeset(message_id, user_id, reaction) do
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      user_id: user_id,
      reaction: reaction
    })
    |> put_change(:created_at, DateTime.utc_now())
  end

  @doc """
  Liste des réactions valides
  """
  def valid_reactions, do: @valid_reactions

  @doc """
  Normalise une réaction (convertit les alias vers les emojis)
  """
  def normalize_reaction(reaction) do
    case reaction do
      "+1" -> "👍"
      "-1" -> "👎"
      "heart" -> "❤️"
      "laugh" -> "😂"
      "wow" -> "😮"
      "sad" -> "😢"
      "angry" -> "😡"
      emoji when emoji in @valid_reactions -> emoji
      _ -> {:error, :invalid_reaction}
    end
  end

  defp put_created_at_if_new(changeset) do
    case get_field(changeset, :created_at) do
      nil -> put_change(changeset, :created_at, DateTime.utc_now())
      _ -> changeset
    end
  end
end
