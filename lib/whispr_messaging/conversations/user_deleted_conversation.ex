defmodule WhisprMessaging.Conversations.UserDeletedConversation do
  @moduledoc """
  Tracks per-user conversation deletion (delete conversation for me).

  When a user deletes a conversation "for me", a record is created here
  so the conversation is hidden from that user but remains visible to others.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_deleted_conversations" do
    field :user_id, :binary_id
    field :deleted_at, :utc_datetime

    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  def changeset(user_deleted_conversation, attrs) do
    user_deleted_conversation
    |> cast(attrs, [:conversation_id, :user_id, :deleted_at])
    |> validate_required([:conversation_id, :user_id, :deleted_at])
    |> unique_constraint([:conversation_id, :user_id],
      name: :user_deleted_conversations_conv_user_index
    )
  end

  @doc """
  Query to check if a user has deleted a specific conversation.
  """
  def by_conversation_and_user_query(conversation_id, user_id) do
    from udc in __MODULE__,
      where: udc.conversation_id == ^conversation_id and udc.user_id == ^user_id
  end

  @doc """
  Query to get all conversation IDs deleted by a user.
  """
  def deleted_conversation_ids_for_user_query(user_id) do
    from udc in __MODULE__,
      where: udc.user_id == ^user_id,
      select: udc.conversation_id
  end
end
