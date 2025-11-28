defmodule WhisprMessaging.Messages.MessageReaction do
  @moduledoc """
  Ecto schema for message reactions (emoji responses).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_reactions" do
    field :user_id, :binary_id
    field :reaction, :string

    belongs_to :message, Message, foreign_key: :message_id

    timestamps()
  end

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:message_id, :user_id, :reaction])
    |> validate_required([:message_id, :user_id, :reaction])
    |> validate_length(:reaction, max: 10)
    |> unique_constraint([:message_id, :user_id, :reaction],
      name: :message_reactions_message_id_user_id_reaction_index
    )
  end

  def by_message_query(message_id) do
    from r in __MODULE__,
      where: r.message_id == ^message_id,
      order_by: [asc: r.inserted_at]
  end

  def reaction_summary_query(message_id) do
    from r in __MODULE__,
      where: r.message_id == ^message_id,
      group_by: r.reaction,
      select: {r.reaction, count(r.id)},
      order_by: [desc: count(r.id)]
  end
end
