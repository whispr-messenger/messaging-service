defmodule WhisprMessaging.Messages.UserMessageDeletion do
  @moduledoc """
  Tracks per-user message deletions ("delete for me").

  When a user deletes a message only for themselves, a record is inserted here
  instead of flipping the global `is_deleted` flag on the message.  Message
  listing queries LEFT JOIN this table to exclude rows the requesting user
  has individually deleted.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_message_deletions" do
    field :user_id, :binary_id

    belongs_to :message, Message, foreign_key: :message_id

    field :inserted_at, :naive_datetime, read_after_writes: true
  end

  @doc """
  Creates a changeset for a new per-user deletion record.
  """
  def changeset(deletion \\ %__MODULE__{}, attrs) do
    deletion
    |> cast(attrs, [:user_id, :message_id])
    |> validate_required([:user_id, :message_id])
    |> unique_constraint([:user_id, :message_id],
      name: :user_message_deletions_user_id_message_id_index
    )
    |> foreign_key_constraint(:message_id, name: :user_message_deletions_message_id_fkey)
  end
end
