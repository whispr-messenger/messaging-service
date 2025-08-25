defmodule WhisprMessaging.Conversations.Conversation do
  @moduledoc """
  Schéma pour les conversations selon la documentation database_design.md
  """
  use Ecto.Schema
  import Ecto.Changeset
  
  alias WhisprMessaging.Conversations.{ConversationMember, ConversationSettings}
  alias WhisprMessaging.Messages.{Message, PinnedMessage}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :type, :string
    field :external_group_id, :binary_id
    field :metadata, :map, default: %{}
    field :is_active, :boolean, default: true

    has_many :members, ConversationMember
    has_many :messages, Message
    has_many :pinned_messages, PinnedMessage
    has_one :settings, ConversationSettings

    timestamps()
  end

  @doc """
  Changeset pour créer ou modifier une conversation
  """
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:type, :external_group_id, :metadata, :is_active])
    |> validate_required([:type])
    |> validate_inclusion(:type, ["direct", "group"])
    |> validate_metadata()
  end

  @doc """
  Changeset pour créer une conversation directe
  """
  def direct_changeset(attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :type, "direct"))
    |> validate_direct_conversation()
  end

  @doc """
  Changeset pour créer une conversation de groupe
  """
  def group_changeset(attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :type, "group"))
    |> validate_required([:external_group_id])
    |> validate_group_conversation()
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      metadata when is_map(metadata) -> changeset
      _ -> add_error(changeset, :metadata, "must be a valid map")
    end
  end

  defp validate_direct_conversation(changeset) do
    changeset
    |> validate_change(:external_group_id, fn :external_group_id, value ->
      if is_nil(value) do
        []
      else
        [external_group_id: "must be nil for direct conversations"]
      end
    end)
  end

  defp validate_group_conversation(changeset) do
    changeset
    |> validate_required([:external_group_id])
  end
end
