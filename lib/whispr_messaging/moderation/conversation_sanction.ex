defmodule WhisprMessaging.Moderation.ConversationSanction do
  @moduledoc """
  Ecto schema for conversation-level sanctions.

  Sanctions restrict a user's ability to participate in a specific conversation
  (mute, kick, or shadow restrict).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_types ~w(mute kick shadow_restrict)

  schema "conversation_sanctions" do
    field :user_id, :binary_id
    field :type, :string
    field :reason, :string
    field :issued_by, :binary_id
    field :expires_at, :utc_datetime
    field :active, :boolean, default: true

    belongs_to :conversation, Conversation

    timestamps(updated_at: false)
  end

  @required_fields ~w(conversation_id user_id type reason issued_by)a
  @optional_fields ~w(expires_at)a

  def changeset(sanction, attrs) do
    sanction
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @valid_types)
    |> foreign_key_constraint(:conversation_id)
  end

  def lift_changeset(sanction) do
    change(sanction, %{active: false})
  end

  # Queries

  def active_for_conversation(query \\ __MODULE__, conversation_id) do
    from s in query,
      where: s.conversation_id == ^conversation_id and s.active == true,
      order_by: [desc: s.inserted_at]
  end

  def active_for_user_in_conversation(query \\ __MODULE__, conversation_id, user_id) do
    from s in query,
      where: s.conversation_id == ^conversation_id and s.user_id == ^user_id and s.active == true
  end

  def expired(query \\ __MODULE__) do
    now = DateTime.utc_now()

    from s in query,
      where: s.active == true and not is_nil(s.expires_at) and s.expires_at <= ^now
  end

  def valid_types, do: @valid_types
end
