defmodule WhisprMessagingWeb.ChannelHelpers do
  @moduledoc """
  Pure helpers extracted from the various channels (ConversationChannel,
  UserChannel) so the encoding/serialization logic can be unit-tested
  in isolation. External wire format is unchanged.
  """

  alias WhisprMessaging.Messages.Message
  alias WhisprMessagingWeb.JsonHelpers

  @doc """
  Renders binary content for JSON encoding. Falls back to Base64 when the
  content is not valid UTF-8, and to `to_string/1` for non-binary inputs.
  """
  @spec safe_binary_content(any()) :: String.t() | nil
  def safe_binary_content(nil), do: nil

  def safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  def safe_binary_content(content), do: to_string(content)

  @doc """
  Inserts `{key, value}` only when value is not `nil`. Used by channels to
  build payloads without conditional `Map.put` blocks.
  """
  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Serializes a `%Message{}` for use as `reply_to` context — a compact subset
  of the full message payload.
  """
  @spec serialize_reply_context(Message.t()) :: map()
  def serialize_reply_context(%Message{} = parent) do
    %{
      id: parent.id,
      sender_id: parent.sender_id,
      content: safe_binary_content(parent.content),
      message_type: parent.message_type,
      is_deleted: parent.is_deleted
    }
  end

  @doc """
  Renders a `MessageReaction` (or a map shaped like one) in camelCase.
  """
  @spec serialize_reaction(map()) :: map()
  def serialize_reaction(reaction) do
    JsonHelpers.camelize_keys(%{
      id: reaction.id,
      message_id: reaction.message_id,
      user_id: reaction.user_id,
      reaction: reaction.reaction,
      inserted_at: reaction.inserted_at
    })
  end

  @doc """
  Renders Ecto changeset errors using `String.replace` interpolation —
  matches the existing wire format from ConversationChannel.
  """
  @spec format_changeset_errors(Ecto.Changeset.t()) :: map()
  def format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
