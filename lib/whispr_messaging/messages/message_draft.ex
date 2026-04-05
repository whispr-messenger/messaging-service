defmodule WhisprMessaging.Messages.MessageDraft do
  @moduledoc """
  Ecto schema for message drafts.

  A draft is an in-progress message that has not been sent yet.
  Only one draft per user per conversation is allowed (upsert semantics).
  Content is stored encrypted (BYTEA) consistent with sent messages.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WhisprMessaging.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_drafts" do
    field :user_id, :binary_id
    field :content, :binary
    field :metadata, :map, default: %{}

    belongs_to :conversation, Conversation, foreign_key: :conversation_id

    timestamps()
  end

  @doc """
  Creates a changeset for a message draft.
  """
  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:conversation_id, :user_id, :content, :metadata])
    |> validate_required([:conversation_id, :user_id, :content])
    |> validate_content_size()
    |> validate_metadata()
    |> unique_constraint([:conversation_id, :user_id],
      name: :message_drafts_conversation_id_user_id_index
    )
    |> foreign_key_constraint(:conversation_id, name: :message_drafts_conversation_id_fkey)
  end

  @doc """
  Query to get the draft for a specific user in a conversation.
  """
  def by_conversation_and_user_query(conversation_id, user_id) do
    from d in __MODULE__,
      where: d.conversation_id == ^conversation_id and d.user_id == ^user_id
  end

  @doc """
  Query to get all drafts for a user across all conversations.
  """
  def by_user_query(user_id) do
    from d in __MODULE__,
      where: d.user_id == ^user_id,
      order_by: [desc: d.updated_at]
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
