defmodule WhisprMessaging.Messages.PinnedMessage do
  @moduledoc """
  Ecto schema for pinned messages in conversations.

  Tracks which messages have been pinned, by whom, and when.
  A message can only be pinned once per conversation.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pinned_messages" do
    field :pinned_by, :binary_id
    field :pinned_at, :utc_datetime

    belongs_to :message, Message, foreign_key: :message_id
    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  def changeset(pinned_message, attrs) do
    pinned_message
    |> cast(attrs, [:message_id, :conversation_id, :pinned_by, :pinned_at])
    |> validate_required([:message_id, :conversation_id, :pinned_by, :pinned_at])
    |> unique_constraint(:message_id, name: :pinned_messages_message_id_index)
    |> foreign_key_constraint(:message_id, name: :pinned_messages_message_id_fkey)
    |> foreign_key_constraint(:conversation_id, name: :pinned_messages_conversation_id_fkey)
  end

  @doc """
  Query to get all pinned messages for a conversation, ordered by pin time.
  """
  def by_conversation_query(conversation_id) do
    from pm in __MODULE__,
      where: pm.conversation_id == ^conversation_id,
      order_by: [desc: pm.pinned_at],
      preload: [:message]
  end

  @doc """
  Query to find a pinned message by message_id.
  """
  def by_message_query(message_id) do
    from pm in __MODULE__,
      where: pm.message_id == ^message_id
  end
end
