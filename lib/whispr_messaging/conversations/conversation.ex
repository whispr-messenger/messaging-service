defmodule WhisprMessaging.Conversations.Conversation do
  @moduledoc """
  Ecto schema for conversations in the messaging system.

  A conversation represents a chat between users (direct) or a group chat.
  This schema handles metadata and relationships for conversations.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.{ConversationMember, ConversationSettings}
  alias WhisprMessaging.Messages.{Message, PinnedMessage}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @conversation_types ~w(direct group)

  schema "conversations" do
    field :type, :string
    field :external_group_id, :binary_id
    field :metadata, :map, default: %{}
    field :is_active, :boolean, default: true

    has_many :members, ConversationMember, foreign_key: :conversation_id
    has_many :messages, Message, foreign_key: :conversation_id
    has_many :pinned_messages, PinnedMessage, foreign_key: :conversation_id
    has_one :settings, ConversationSettings, foreign_key: :conversation_id

    timestamps()
  end

  @doc """
  Creates a changeset for conversation creation.
  """
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:type, :external_group_id, :metadata, :is_active])
    |> validate_required([:type])
    |> validate_inclusion(:type, @conversation_types)
    |> validate_metadata()
    |> unique_constraint(:external_group_id, name: :conversations_external_group_id_index)
  end

  @doc """
  Changeset for updating conversation metadata.
  """
  def update_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:metadata, :is_active])
    |> validate_metadata()
  end

  @doc """
  Query to find conversations by user ID.
  """
  def by_user_query(user_id) do
    from c in __MODULE__,
      join: m in ConversationMember,
      on: m.conversation_id == c.id,
      where: m.user_id == ^user_id and m.is_active == true and c.is_active == true,
      order_by: [desc: c.updated_at]
  end

  @doc """
  Query to find a direct conversation between two users.
  """
  def direct_conversation_query(user_id1, user_id2) do
    from c in __MODULE__,
      join: m1 in ConversationMember,
      on: m1.conversation_id == c.id,
      join: m2 in ConversationMember,
      on: m2.conversation_id == c.id,
      where: c.type == "direct" and c.is_active == true,
      where: m1.user_id == ^user_id1 and m1.is_active == true,
      where: m2.user_id == ^user_id2 and m2.is_active == true,
      where: m1.id != m2.id
  end

  @doc """
  Query to find conversation by external group ID.
  """
  def by_external_group_query(external_group_id) do
    from c in __MODULE__,
      where: c.external_group_id == ^external_group_id and c.is_active == true
  end

  @doc """
  Query to get conversation with members preloaded.
  """
  def with_members_query(conversation_id) do
    from c in __MODULE__,
      where: c.id == ^conversation_id,
      preload: [members: :user]
  end

  @doc """
  Query to get conversation with recent messages.
  """
  def with_recent_messages_query(conversation_id, limit \\ 50) do
    recent_messages_query =
      from m in Message,
        where: m.conversation_id == ^conversation_id and m.is_deleted == false,
        order_by: [desc: m.sent_at],
        limit: ^limit

    from c in __MODULE__,
      where: c.id == ^conversation_id,
      preload: [messages: ^recent_messages_query]
  end

  @doc """
  Validates conversation metadata based on type.
  """
  defp validate_metadata(%Ecto.Changeset{} = changeset) do
    conversation_type = get_field(changeset, :type)
    metadata = get_field(changeset, :metadata) || %{}

    case conversation_type do
      "group" ->
        changeset
        |> validate_group_metadata(metadata)

      "direct" ->
        changeset
        |> validate_direct_metadata(metadata)

      _ ->
        changeset
    end
  end

  defp validate_group_metadata(changeset, metadata) do
    # Group conversations should have a name
    case Map.get(metadata, "name") do
      nil ->
        add_error(changeset, :metadata, "Group conversations must have a name")

      name when is_binary(name) and byte_size(name) > 0 ->
        if byte_size(name) <= 100 do
          changeset
        else
          add_error(changeset, :metadata, "Group name cannot exceed 100 characters")
        end

      _ ->
        add_error(changeset, :metadata, "Group name must be a string")
    end
  end

  defp validate_direct_metadata(changeset, _metadata) do
    # Direct conversations don't require specific metadata validation
    changeset
  end

  @doc """
  Creates a new direct conversation between two users.
  """
  def create_direct_conversation(user_id1, user_id2, metadata \\ %{}) do
    %__MODULE__{}
    |> changeset(%{
      type: "direct",
      metadata: metadata
    })
  end

  @doc """
  Creates a new group conversation.
  """
  def create_group_conversation(name, external_group_id, metadata \\ %{}) do
    group_metadata = Map.put(metadata, "name", name)

    %__MODULE__{}
    |> changeset(%{
      type: "group",
      external_group_id: external_group_id,
      metadata: group_metadata
    })
  end

  @doc """
  Checks if a conversation is a direct message.
  """
  def direct?(%__MODULE__{type: "direct"}), do: true
  def direct?(_), do: false

  @doc """
  Checks if a conversation is a group.
  """
  def group?(%__MODULE__{type: "group"}), do: true
  def group?(_), do: false

  @doc """
  Gets the display name for a conversation.
  """
  def display_name(%__MODULE__{type: "group", metadata: metadata}) do
    Map.get(metadata, "name", "Unnamed Group")
  end

  def display_name(%__MODULE__{type: "direct"}) do
    "Direct Message"
  end

  @doc """
  Gets conversation metadata safely.
  """
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Updates conversation metadata.
  """
  def put_metadata(%__MODULE__{metadata: metadata} = conversation, key, value) do
    new_metadata = Map.put(metadata, key, value)
    %{conversation | metadata: new_metadata}
  end
end
