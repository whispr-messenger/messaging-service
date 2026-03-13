defmodule WhisprMessaging.Conversations.PinnedConversation do
  @moduledoc """
  Tracks pinned conversations per user.

  Each user can pin conversations that are important to them.
  Pinned conversations appear at the top of the conversation list.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pinned_conversations" do
    field :user_id, :binary_id
    field :pinned_at, :utc_datetime

    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  def changeset(pinned_conversation, attrs) do
    pinned_conversation
    |> cast(attrs, [:conversation_id, :user_id, :pinned_at])
    |> validate_required([:conversation_id, :user_id, :pinned_at])
    |> unique_constraint([:conversation_id, :user_id],
      name: :pinned_conversations_conv_user_index
    )
  end

  @doc """
  Query to find a pinned conversation for a user.
  """
  def by_conversation_and_user_query(conversation_id, user_id) do
    from pc in __MODULE__,
      where: pc.conversation_id == ^conversation_id and pc.user_id == ^user_id
  end

  @doc """
  Query to list all pinned conversations for a user.
  """
  def by_user_query(user_id) do
    from pc in __MODULE__,
      where: pc.user_id == ^user_id,
      order_by: [desc: pc.pinned_at]
  end

  @doc """
  Query to list pinned conversation IDs for a user.
  """
  def pinned_conversation_ids_for_user_query(user_id) do
    from pc in __MODULE__,
      where: pc.user_id == ^user_id,
      select: pc.conversation_id
  end
end
