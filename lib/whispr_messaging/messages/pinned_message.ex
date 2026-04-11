defmodule WhisprMessaging.Messages.PinnedMessage do
  @moduledoc """
  Ecto schema for pinned messages within a conversation.
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
    field :pinned_at, :naive_datetime

    belongs_to :message, Message, foreign_key: :message_id
    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  def changeset(pinned_message, attrs) do
    pinned_message
    |> cast(attrs, [:message_id, :conversation_id, :pinned_by, :pinned_at])
    |> put_pinned_at()
    |> validate_required([:message_id, :conversation_id, :pinned_by, :pinned_at])
    |> unique_constraint(:message_id, name: :pinned_messages_message_id_index)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:conversation_id)
  end

  defp put_pinned_at(changeset) do
    case get_field(changeset, :pinned_at) do
      nil -> put_change(changeset, :pinned_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
      _ -> changeset
    end
  end

  @doc """
  Query for pinned messages in a conversation, newest first.
  """
  def by_conversation_query(conversation_id) do
    from p in __MODULE__,
      where: p.conversation_id == ^conversation_id,
      order_by: [desc: p.inserted_at],
      preload: [:message]
  end
end
