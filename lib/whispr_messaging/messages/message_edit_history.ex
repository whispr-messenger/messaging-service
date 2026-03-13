defmodule WhisprMessaging.Messages.MessageEditHistory do
  @moduledoc """
  Tracks edit history for messages.

  Each time a message is edited, the previous content is stored here
  so users can view the edit history of a message.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_edit_history" do
    field :old_content, :binary
    field :edited_by, :binary_id
    field :edited_at, :utc_datetime

    belongs_to :message, Message, foreign_key: :message_id

    timestamps()
  end

  def changeset(edit_history, attrs) do
    edit_history
    |> cast(attrs, [:message_id, :old_content, :edited_by, :edited_at])
    |> validate_required([:message_id, :old_content, :edited_by, :edited_at])
  end

  @doc """
  Query to get edit history for a message, ordered chronologically.
  """
  def by_message_query(message_id) do
    from eh in __MODULE__,
      where: eh.message_id == ^message_id,
      order_by: [desc: eh.edited_at]
  end
end
