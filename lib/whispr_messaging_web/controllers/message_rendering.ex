defmodule WhisprMessagingWeb.MessageRendering do
  @moduledoc """
  Rendering and parsing helpers extracted from `MessageController` for
  testability. External REST contract is preserved — these helpers are
  called by the controller actions.
  """

  alias WhisprMessaging.Messages.DeliveryStatus
  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  @doc """
  Renders a list of messages.
  """
  @spec render_messages([map()]) :: [map()]
  def render_messages(messages), do: Enum.map(messages, &render_message/1)

  @doc """
  Renders a single message with aggregated delivery_status and optional
  reply_to context.
  """
  @spec render_message(map()) :: map()
  def render_message(message) do
    base = %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_id: message.sender_id,
      content: safe_binary_content(message.content),
      message_type: message.message_type,
      metadata: message.metadata,
      reply_to_id: message.reply_to_id,
      forwarded_from_id: Map.get(message, :forwarded_from_id),
      is_edited: message.edited_at != nil,
      edited_at: message.edited_at,
      is_deleted: message.is_deleted,
      is_ephemeral: not is_nil(message.expires_at),
      expires_at: message.expires_at,
      sent_at: message.sent_at,
      inserted_at: message.inserted_at,
      updated_at: message.updated_at
    }

    result =
      case message do
        %{delivery_statuses: statuses} when is_list(statuses) ->
          Map.put(base, :delivery_status, DeliveryStatus.compute_aggregate_status(statuses))

        _ ->
          Map.put(base, :delivery_status, "sent")
      end

    result =
      case message do
        %{reply_to: %WhisprMessaging.Messages.Message{} = parent} ->
          Map.put(result, :reply_to, render_reply_context(parent))

        _ ->
          result
      end

    camelize_keys(result)
  end

  @doc """
  Renders the parent message context (for replies).
  """
  @spec render_reply_context(map()) :: map()
  def render_reply_context(parent_message) do
    %{
      id: parent_message.id,
      sender_id: parent_message.sender_id,
      content: safe_binary_content(parent_message.content),
      message_type: parent_message.message_type,
      is_deleted: parent_message.is_deleted
    }
  end

  @doc """
  Safely returns a binary as a JSON-friendly string (Base64-encodes invalid UTF-8).
  """
  @spec safe_binary_content(any()) :: String.t() | nil
  def safe_binary_content(nil), do: nil

  def safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  def safe_binary_content(content), do: to_string(content)

  @doc """
  Translates the convenience param `ttl_seconds` into an explicit
  `expires_at` timestamp. If both are provided, `expires_at` wins.
  """
  @spec resolve_ttl_seconds(map()) :: map()
  def resolve_ttl_seconds(%{"expires_at" => _} = params), do: params

  def resolve_ttl_seconds(%{"ttl_seconds" => ttl} = params)
      when is_integer(ttl) and ttl > 0 do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.truncate(:second)

    params
    |> Map.put("expires_at", expires_at)
    |> Map.delete("ttl_seconds")
  end

  def resolve_ttl_seconds(params), do: params

  @doc """
  Extracts up to ~100 chars of `preview` around the first match of `query`
  for the search list view. Returns the preview when it's already short
  enough, the matched slice otherwise.
  """
  @spec build_truncated_preview(String.t() | nil, String.t()) :: String.t() | nil
  def build_truncated_preview(nil, _query), do: nil

  def build_truncated_preview(preview, _query) when byte_size(preview) <= 100, do: preview

  def build_truncated_preview(preview, query) do
    case :binary.match(String.downcase(preview), String.downcase(query)) do
      {start, _len} ->
        from = max(0, start - 30)
        String.slice(preview, from, 100)

      :nomatch ->
        String.slice(preview, 0, 100)
    end
  end

  @doc "Appends `{key, value}` to opts unless value is nil or empty string."
  @spec maybe_put_opt(keyword(), atom(), any()) :: keyword()
  def maybe_put_opt(opts, _key, nil), do: opts
  def maybe_put_opt(opts, _key, ""), do: opts
  def maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Parses `value` to integer, falling back to `default` on failure."
  @spec parse_int(any(), integer()) :: integer()
  def parse_int(value, _default) when is_integer(value), do: value

  def parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(_, default), do: default

  @doc "Returns :unauthorized when `user_id` is nil, :ok otherwise."
  @spec ensure_receipt_user(String.t() | nil) :: :ok | :unauthorized
  def ensure_receipt_user(nil), do: :unauthorized
  def ensure_receipt_user(_user_id), do: :ok

  @doc "Whitelist of valid receipt status values."
  @spec valid_receipt_status(any()) :: boolean()
  def valid_receipt_status("delivered"), do: true
  def valid_receipt_status("read"), do: true
  def valid_receipt_status(_), do: false
end
