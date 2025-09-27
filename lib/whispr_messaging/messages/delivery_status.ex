defmodule WhisprMessaging.Messages.DeliveryStatus do
  @moduledoc """
  Ecto schema for tracking message delivery and read status.

  This tracks when messages are delivered to and read by each recipient.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Messages.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "delivery_statuses" do
    field :user_id, :binary_id
    field :delivered_at, :utc_datetime
    field :read_at, :utc_datetime

    belongs_to :message, Message, foreign_key: :message_id

    timestamps()
  end

  @doc """
  Creates a changeset for delivery status.
  """
  def changeset(delivery_status, attrs) do
    delivery_status
    |> cast(attrs, [:message_id, :user_id, :delivered_at, :read_at])
    |> validate_required([:message_id, :user_id])
    |> unique_constraint([:message_id, :user_id],
      name: :delivery_statuses_message_id_user_id_index
    )
  end

  @doc """
  Changeset for marking a message as delivered.
  """
  def mark_delivered_changeset(delivery_status, timestamp \\ nil) do
    delivered_time = timestamp || DateTime.utc_now()

    delivery_status
    |> cast(%{delivered_at: delivered_time}, [:delivered_at])
  end

  @doc """
  Changeset for marking a message as read.
  """
  def mark_read_changeset(delivery_status, timestamp \\ nil) do
    read_time = timestamp || DateTime.utc_now()

    delivery_status
    |> cast(%{read_at: read_time}, [:read_at])
    |> maybe_set_delivered_at(read_time)
  end

  @doc """
  Query to get delivery statuses for a message.
  """
  def by_message_query(message_id) do
    from ds in __MODULE__,
      where: ds.message_id == ^message_id,
      order_by: [asc: ds.delivered_at]
  end

  @doc """
  Query to get delivery status for a specific user and message.
  """
  def by_message_and_user_query(message_id, user_id) do
    from ds in __MODULE__,
      where: ds.message_id == ^message_id and ds.user_id == ^user_id
  end

  @doc """
  Query to get undelivered messages for a user.
  """
  def undelivered_for_user_query(user_id) do
    from ds in __MODULE__,
      where: ds.user_id == ^user_id and is_nil(ds.delivered_at),
      join: m in Message,
      on: m.id == ds.message_id,
      where: m.is_deleted == false,
      select: {ds, m},
      order_by: [asc: m.sent_at]
  end

  @doc """
  Query to get unread messages for a user.
  """
  def unread_for_user_query(user_id) do
    from ds in __MODULE__,
      where: ds.user_id == ^user_id,
      where: not is_nil(ds.delivered_at) and is_nil(ds.read_at),
      join: m in Message,
      on: m.id == ds.message_id,
      where: m.is_deleted == false,
      select: {ds, m},
      order_by: [asc: m.sent_at]
  end

  @doc """
  Query to get read receipt summary for a message.
  """
  def read_receipt_summary_query(message_id) do
    from ds in __MODULE__,
      where: ds.message_id == ^message_id,
      select: %{
        total_recipients: count(ds.id),
        delivered_count: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", ds.delivered_at)),
        read_count: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", ds.read_at))
      }
  end

  @doc """
  Creates delivery statuses for all conversation members.
  """
  def create_for_conversation_members(message_id, conversation_id, sender_id) do
    # This would typically be called as part of a raw SQL query for efficiency
    """
    INSERT INTO delivery_statuses (id, message_id, user_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), $1, cm.user_id, NOW(), NOW()
    FROM conversation_members cm
    WHERE cm.conversation_id = $2
      AND cm.user_id != $3
      AND cm.is_active = true
    """
  end

  @doc """
  Creates a new delivery status record.
  """
  def create_delivery_status(message_id, user_id) do
    %__MODULE__{}
    |> changeset(%{
      message_id: message_id,
      user_id: user_id
    })
  end

  @doc """
  Sets delivered_at if not already set when marking as read.
  """
  defp maybe_set_delivered_at(%Ecto.Changeset{} = changeset, read_time) do
    case get_field(changeset, :delivered_at) do
      nil ->
        put_change(changeset, :delivered_at, read_time)

      _ ->
        changeset
    end
  end

  @doc """
  Checks if message has been delivered.
  """
  def delivered?(%__MODULE__{delivered_at: nil}), do: false
  def delivered?(%__MODULE__{delivered_at: _}), do: true

  @doc """
  Checks if message has been read.
  """
  def read?(%__MODULE__{read_at: nil}), do: false
  def read?(%__MODULE__{read_at: _}), do: true

  @doc """
  Gets delivery time duration in milliseconds.
  """
  def delivery_duration_ms(%__MODULE__{delivered_at: nil}, _), do: nil

  def delivery_duration_ms(%__MODULE__{delivered_at: delivered_at}, sent_at) do
    DateTime.diff(delivered_at, sent_at, :millisecond)
  end

  @doc """
  Gets read time duration in milliseconds from sent time.
  """
  def read_duration_ms(%__MODULE__{read_at: nil}, _), do: nil

  def read_duration_ms(%__MODULE__{read_at: read_at}, sent_at) do
    DateTime.diff(read_at, sent_at, :millisecond)
  end
end