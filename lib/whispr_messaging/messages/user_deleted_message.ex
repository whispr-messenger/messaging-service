defmodule WhisprMessaging.Messages.UserDeletedMessage do
  @moduledoc """
  Tracks per-user message deletion (delete for me).

  When a user deletes a message "for me", a record is created here
  so the message is hidden from that user but remains visible to others.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_deleted_messages" do
    field :user_id, :binary_id
    field :deleted_at, :utc_datetime

    belongs_to :message, Message, foreign_key: :message_id

    timestamps()
  end

  def changeset(user_deleted_message, attrs) do
    user_deleted_message
    |> cast(attrs, [:message_id, :user_id, :deleted_at])
    |> validate_required([:message_id, :user_id, :deleted_at])
    |> unique_constraint([:message_id, :user_id],
      name: :user_deleted_messages_message_id_user_id_index
    )
  end

  @doc """
  Query to check if a user has deleted a specific message.
  """
  def by_message_and_user_query(message_id, user_id) do
    from udm in __MODULE__,
      where: udm.message_id == ^message_id and udm.user_id == ^user_id
  end

  @doc """
  Query to get all message IDs deleted by a user in a conversation.
  """
  def deleted_message_ids_for_user_query(user_id, message_ids) do
    from udm in __MODULE__,
      where: udm.user_id == ^user_id and udm.message_id in ^message_ids,
      select: udm.message_id
  end
end
