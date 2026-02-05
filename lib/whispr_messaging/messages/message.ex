defmodule WhisprMessaging.Messages.Message do
  @moduledoc """
  Ecto schema for messages in conversations.

  Messages are the core communication units in the messaging system.
  Content is stored encrypted (BYTEA) as per E2E encryption requirements.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Messages.{DeliveryStatus, MessageAttachment, MessageReaction}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @message_types ~w(text media system)

  schema "messages" do
    field :sender_id, :binary_id
    field :message_type, :string
    # Encrypted content as BYTEA
    field :content, :binary
    field :metadata, :map, default: %{}
    field :client_random, :integer
    field :sent_at, :utc_datetime
    field :edited_at, :utc_datetime
    field :is_deleted, :boolean, default: false
    field :delete_for_everyone, :boolean, default: false

    belongs_to :conversation, Conversation, foreign_key: :conversation_id
    belongs_to :reply_to, __MODULE__, foreign_key: :reply_to_id
    has_many :delivery_statuses, DeliveryStatus, foreign_key: :message_id
    has_many :reactions, MessageReaction, foreign_key: :message_id
    has_many :attachments, MessageAttachment, foreign_key: :message_id
    has_many :replies, __MODULE__, foreign_key: :reply_to_id

    timestamps()
  end

  @doc """
  Creates a changeset for a new message.
  """
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :sender_id,
      :reply_to_id,
      :message_type,
      :content,
      :metadata,
      :client_random,
      :sent_at
    ])
    |> validate_required([:conversation_id, :sender_id, :message_type, :content, :client_random])
    |> validate_inclusion(:message_type, @message_types)
    |> validate_content_size()
    |> validate_metadata()
    |> put_sent_at_if_empty()
    |> unique_constraint([:sender_id, :client_random],
      name: :messages_sender_id_client_random_index
    )
    |> foreign_key_constraint(:conversation_id, name: :messages_conversation_id_fkey)
  end

  @doc """
  Changeset for editing a message.
  """
  def edit_changeset(message, new_content, metadata \\ %{}) do
    message
    |> cast(
      %{
        content: new_content,
        metadata: Map.merge(message.metadata, metadata),
        edited_at: DateTime.utc_now()
      },
      [:content, :metadata, :edited_at]
    )
    |> validate_required([:content])
    |> validate_content_size()
    |> validate_metadata()
  end

  @doc """
  Changeset for soft deleting a message.
  """
  def delete_changeset(message, delete_for_everyone \\ false) do
    message
    |> cast(
      %{
        is_deleted: true,
        delete_for_everyone: delete_for_everyone
      },
      [:is_deleted, :delete_for_everyone]
    )
  end

  @doc """
  Query to get recent messages from a conversation.
  """
  def recent_messages_query(conversation_id, limit \\ 50, before_timestamp \\ nil) do
    query =
      from m in __MODULE__,
        where: m.conversation_id == ^conversation_id and m.is_deleted == false,
        order_by: [desc: m.sent_at],
        limit: ^limit

    case before_timestamp do
      nil -> query
      timestamp -> from m in query, where: m.sent_at < ^timestamp
    end
  end

  @doc """
  Query to get messages after a specific timestamp.
  """
  def messages_after_query(conversation_id, timestamp) do
    from m in __MODULE__,
      where: m.conversation_id == ^conversation_id,
      where: m.sent_at > ^timestamp,
      where: m.is_deleted == false,
      order_by: [asc: m.sent_at]
  end

  @doc """
  Query to get undelivered messages for a user.
  """
  def undelivered_messages_query(user_id) do
    from m in __MODULE__,
      left_join: ds in DeliveryStatus,
      on: ds.message_id == m.id and ds.user_id == ^user_id,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      join: cm in "conversation_members",
      on: cm.conversation_id == c.id and cm.user_id == ^user_id,
      where: is_nil(ds.id) and m.sender_id != ^user_id,
      where: m.is_deleted == false and cm.is_active == true,
      order_by: [asc: m.sent_at]
  end

  @doc """
  Query to search messages by content (when decrypted client-side).
  """
  def search_messages_query(conversation_id, search_term) when is_binary(search_term) do
    # Note: This is for metadata search only since content is encrypted
    search_pattern = "%#{search_term}%"

    from m in __MODULE__,
      where: m.conversation_id == ^conversation_id,
      where: m.is_deleted == false,
      where: ilike(fragment("?::text", m.metadata), ^search_pattern),
      order_by: [desc: m.sent_at]
  end

  @doc """
  Query to get message with all related data.
  """
  def with_relations_query(message_id) do
    from m in __MODULE__,
      where: m.id == ^message_id,
      preload: [:delivery_statuses, :reactions, :attachments, :reply_to]
  end

  @doc """
  Query to get messages by sender in a conversation.
  """
  def by_sender_query(conversation_id, sender_id) do
    from m in __MODULE__,
      where: m.conversation_id == ^conversation_id,
      where: m.sender_id == ^sender_id,
      where: m.is_deleted == false,
      order_by: [desc: m.sent_at]
  end

  @doc """
  Query to count unread messages for a user in a conversation.
  """
  def unread_count_query(conversation_id, user_id, last_read_at) do
    query =
      from m in __MODULE__,
        where: m.conversation_id == ^conversation_id,
        where: m.sender_id != ^user_id,
        where: m.is_deleted == false,
        select: count(m.id)

    case last_read_at do
      nil -> query
      timestamp -> from m in query, where: m.sent_at > ^timestamp
    end
  end

  @doc """
  Creates a new text message.
  """
  def create_text_message(
        conversation_id,
        sender_id,
        encrypted_content,
        client_random,
        metadata \\ %{}
      ) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      message_type: "text",
      content: encrypted_content,
      metadata: metadata,
      client_random: client_random
    })
  end

  @doc """
  Creates a new media message.
  """
  def create_media_message(conversation_id, sender_id, encrypted_content, client_random, metadata) do
    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      sender_id: sender_id,
      message_type: "media",
      content: encrypted_content,
      metadata: metadata,
      client_random: client_random
    })
  end

  @doc """
  Creates a system message (notifications, member changes, etc.).
  """
  def create_system_message(conversation_id, content, metadata \\ %{}) do
    # System messages use a deterministic client_random based on timestamp
    client_random = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> rem(2_147_483_647)

    %__MODULE__{}
    |> changeset(%{
      conversation_id: conversation_id,
      # System messages have no sender
      sender_id: nil,
      message_type: "system",
      content: content,
      metadata: metadata,
      client_random: client_random
    })
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

  defp put_sent_at_if_empty(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :sent_at) do
      nil ->
        put_change(changeset, :sent_at, DateTime.utc_now() |> DateTime.truncate(:second))

      _ ->
        changeset
    end
  end

  @doc """
  Checks if a message is a text message.
  """
  def text?(%__MODULE__{message_type: "text"}), do: true
  def text?(_), do: false

  @doc """
  Checks if a message is a media message.
  """
  def media?(%__MODULE__{message_type: "media"}), do: true
  def media?(_), do: false

  @doc """
  Checks if a message is a system message.
  """
  def system?(%__MODULE__{message_type: "system"}), do: true
  def system?(_), do: false

  @doc """
  Checks if a message has been edited.
  """
  def edited?(%__MODULE__{edited_at: nil}), do: false
  def edited?(%__MODULE__{edited_at: _}), do: true

  @doc """
  Checks if a message is deleted.
  """
  def deleted?(%__MODULE__{is_deleted: is_deleted}), do: is_deleted

  @doc """
  Gets a metadata value safely.
  """
  def get_metadata(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Updates message metadata.
  """
  def put_metadata(%__MODULE__{metadata: metadata} = message, key, value) do
    new_metadata = Map.put(metadata, key, value)
    %{message | metadata: new_metadata}
  end

  @doc """
  Calculates message age in seconds.
  """
  def age_seconds(%__MODULE__{sent_at: sent_at}) do
    DateTime.diff(DateTime.utc_now(), sent_at, :second)
  end

  @doc """
  Checks if message can be edited (within edit window).
  """
  def editable?(%__MODULE__{message_type: "system"}), do: false
  def editable?(%__MODULE__{is_deleted: true}), do: false

  def editable?(%__MODULE__{} = message) do
    # Messages can be edited within 24 hours
    age_seconds(message) < 86_400
  end

  @doc """
  Checks if message can be deleted.
  """
  def deletable?(%__MODULE__{is_deleted: true}), do: false

  def deletable?(%__MODULE__{} = message) do
    # Messages can be deleted within 48 hours
    age_seconds(message) < 172_800
  end
end
