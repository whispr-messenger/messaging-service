defmodule WhisprMessaging.Conversations.ConversationMember do
  @moduledoc """
  Ecto schema for conversation members.

  This represents the relationship between users and conversations,
  including their settings and participation status.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_members" do
    field(:user_id, :binary_id)
    field(:settings, :map, default: %{})
    field(:joined_at, :utc_datetime)
    field(:last_read_at, :utc_datetime)
    field(:is_active, :boolean, default: true)

    belongs_to(:conversation, Conversation, foreign_key: :conversation_id)

    timestamps()
  end

  @doc """
  Creates a changeset for adding a member to a conversation.
  """
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:conversation_id, :user_id, :settings, :joined_at, :last_read_at, :is_active])
    |> validate_required([:conversation_id, :user_id])
    |> put_joined_at_if_empty()
    |> validate_settings()
    |> unique_constraint([:conversation_id, :user_id],
      name: :conversation_members_conversation_id_user_id_index
    )
  end

  @doc """
  Changeset for updating member settings.
  """
  def update_settings_changeset(member, settings) do
    member
    |> cast(%{settings: settings}, [:settings])
    |> validate_settings()
  end

  @doc """
  Changeset for updating last read timestamp.
  """
  def mark_read_changeset(member, timestamp \\ nil) do
    read_time = timestamp || DateTime.utc_now()

    member
    |> cast(%{last_read_at: read_time}, [:last_read_at])
  end

  @doc """
  Changeset for deactivating a member (leaving conversation).
  """
  def deactivate_changeset(member) do
    member
    |> cast(%{is_active: false}, [:is_active])
  end

  @doc """
  Query to find active members of a conversation.
  """
  def active_members_query(conversation_id) do
    from(m in __MODULE__,
      where: m.conversation_id == ^conversation_id and m.is_active == true,
      order_by: [asc: m.joined_at]
    )
  end

  @doc """
  Query to find member by conversation and user ID.
  """
  def by_conversation_and_user_query(conversation_id, user_id) do
    from(m in __MODULE__,
      where: m.conversation_id == ^conversation_id and m.user_id == ^user_id
    )
  end

  @doc """
  Query to find conversations for a specific user.
  """
  def user_conversations_query(user_id) do
    from(m in __MODULE__,
      where: m.user_id == ^user_id and m.is_active == true,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: c.is_active == true,
      select: {m, c},
      order_by: [desc: c.updated_at]
    )
  end

  @doc """
  Query to find members who haven't read recent messages.
  """
  def unread_members_query(conversation_id, since_timestamp) do
    from(m in __MODULE__,
      where: m.conversation_id == ^conversation_id and m.is_active == true,
      where: is_nil(m.last_read_at) or m.last_read_at < ^since_timestamp
    )
  end

  @doc """
  Query to count active members in a conversation.
  """
  def count_active_members_query(conversation_id) do
    from(m in __MODULE__,
      where: m.conversation_id == ^conversation_id and m.is_active == true,
      select: count(m.id)
    )
  end

  @doc """
  Creates a new conversation member.
  """
  def create_member(conversation_id, user_id, settings \\ %{}) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      user_id: user_id,
      settings: settings,
      joined_at: DateTime.utc_now()
    })
  end

  @doc """
  Default settings for a conversation member.
  """
  def default_settings do
    %{
      "notifications" => true,
      "sound_enabled" => true,
      "desktop_notifications" => true,
      "mobile_notifications" => true,
      "mention_notifications" => true
    }
  end

  @doc """
  Validates member settings structure.
  """
  defp validate_settings(%Ecto.Changeset{} = changeset) do
    settings = get_field(changeset, :settings) || %{}

    if is_map(settings) do
      changeset
    else
      add_error(changeset, :settings, "must be a map")
    end
  end

  @doc """
  Sets joined_at to current time if not provided.
  """
  defp put_joined_at_if_empty(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :joined_at) do
      nil ->
        put_change(changeset, :joined_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end

  @doc """
  Gets a setting value for a member.
  """
  def get_setting(%__MODULE__{settings: settings}, key, default \\ nil) do
    Map.get(settings, key, default)
  end

  @doc """
  Updates a setting for a member.
  """
  def put_setting(%__MODULE__{settings: settings} = member, key, value) do
    new_settings = Map.put(settings, key, value)
    %{member | settings: new_settings}
  end

  @doc """
  Checks if notifications are enabled for a member.
  """
  def notifications_enabled?(%__MODULE__{} = member) do
    get_setting(member, "notifications", true)
  end

  @doc """
  Checks if a member has unread messages since a given timestamp.
  """
  def has_unread_since?(%__MODULE__{last_read_at: nil}, _timestamp), do: true

  def has_unread_since?(%__MODULE__{last_read_at: last_read}, timestamp) do
    DateTime.compare(last_read, timestamp) == :lt
  end

  @doc """
  Checks if a member is active in the conversation.
  """
  def active?(%__MODULE__{is_active: is_active}), do: is_active

  @doc """
  Gets the duration since the member joined.
  """
  def membership_duration(%__MODULE__{joined_at: joined_at}) do
    DateTime.diff(DateTime.utc_now(), joined_at, :second)
  end
end
