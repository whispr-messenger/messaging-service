defmodule WhisprMessaging.Messages.ScheduledMessage do
  @moduledoc """
  Ecto schema for scheduled messages.

  A scheduled message is queued to be sent at a future `scheduled_at` timestamp.
  A background worker polls for pending messages and dispatches them.

  Status lifecycle: pending -> sent | cancelled | failed
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @message_types ~w(text media)
  @statuses ~w(pending sent cancelled failed)

  schema "scheduled_messages" do
    field :sender_id, :binary_id
    field :content, :binary
    field :message_type, :string, default: "text"
    field :metadata, :map, default: %{}
    field :client_random, :integer
    field :scheduled_at, :utc_datetime
    field :status, :string, default: "pending"

    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  @doc """
  Creates a changeset for a new scheduled message.
  """
  def changeset(scheduled_message, attrs) do
    scheduled_message
    |> cast(attrs, [
      :conversation_id,
      :sender_id,
      :content,
      :message_type,
      :metadata,
      :client_random,
      :scheduled_at
    ])
    |> validate_required([
      :conversation_id,
      :sender_id,
      :content,
      :message_type,
      :client_random,
      :scheduled_at
    ])
    |> validate_inclusion(:message_type, @message_types)
    |> validate_scheduled_at_future()
    |> validate_content_size()
    |> validate_metadata()
    |> foreign_key_constraint(:conversation_id, name: :scheduled_messages_conversation_id_fkey)
    |> unique_constraint([:sender_id, :client_random],
      name: :scheduled_messages_sender_client_random_unique,
      message: "a scheduled message with this client_random already exists"
    )
  end

  @doc """
  Changeset for cancelling a scheduled message.
  """
  def cancel_changeset(scheduled_message) do
    scheduled_message
    |> cast(%{status: "cancelled"}, [:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_can_cancel()
  end

  @doc """
  Changeset for marking a scheduled message as sent.
  """
  def mark_sent_changeset(scheduled_message) do
    scheduled_message
    |> cast(%{status: "sent"}, [:status])
  end

  @doc """
  Changeset for marking a scheduled message as permanently failed.
  """
  def mark_failed_changeset(scheduled_message) do
    scheduled_message
    |> cast(%{status: "failed"}, [:status])
  end

  @doc """
  Query for pending scheduled messages that are due for dispatch.
  """
  def due_messages_query do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from sm in __MODULE__,
      where: sm.status == "pending",
      where: sm.scheduled_at <= ^now,
      order_by: [asc: sm.scheduled_at]
  end

  @doc """
  Query for pending scheduled messages for a user.
  """
  def pending_by_sender_query(sender_id) do
    from sm in __MODULE__,
      where: sm.sender_id == ^sender_id,
      where: sm.status == "pending",
      order_by: [asc: sm.scheduled_at]
  end

  defp validate_scheduled_at_future(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :scheduled_at) do
      nil ->
        changeset

      scheduled_at ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        if DateTime.compare(scheduled_at, now) == :gt do
          changeset
        else
          add_error(changeset, :scheduled_at, "must be in the future")
        end
    end
  end

  defp validate_can_cancel(%Ecto.Changeset{} = changeset) do
    case changeset.data.status do
      "pending" -> changeset
      _ -> add_error(changeset, :status, "can only cancel pending messages")
    end
  end

  defp validate_content_size(%Ecto.Changeset{} = changeset) do
    max_size = Application.get_env(:whispr_messaging, :messages)[:max_content_size] || 65_536

    case get_field(changeset, :content) do
      nil ->
        changeset

      content when is_binary(content) ->
        if byte_size(content) <= max_size do
          changeset
        else
          add_error(changeset, :content, "exceeds maximum size of #{max_size} bytes")
        end

      _ ->
        add_error(changeset, :content, "must be binary data")
    end
  end

  defp validate_metadata(%Ecto.Changeset{} = changeset) do
    metadata = get_field(changeset, :metadata) || %{}

    if is_map(metadata) do
      changeset
    else
      add_error(changeset, :metadata, "must be a map")
    end
  end
end
