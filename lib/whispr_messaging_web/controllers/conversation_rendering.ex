defmodule WhisprMessagingWeb.ConversationRendering do
  @moduledoc """
  Rendering helpers extracted from `ConversationController` for testability.

  These functions are intentionally pure (or close to it) so the rendering
  branches can be exercised in isolation without going through the router.
  External REST contract is preserved — these helpers are called by the
  controller actions.
  """

  alias WhisprMessaging.Services.MediaClient
  import WhisprMessagingWeb.JsonHelpers, only: [camelize_keys: 1]

  @doc """
  Renders a list of conversations.
  """
  @spec render_conversations([map()], String.t() | nil) :: [map()]
  def render_conversations(conversations, authorization) do
    Enum.map(conversations, &render_conversation(&1, authorization))
  end

  @doc """
  Renders a single conversation with its presigned metadata, settings, and
  last message.

  When `:member_info` is present on the conversation, surfaces the user's
  per-conversation settings flags (is_muted, is_pinned, is_archived).
  """
  @spec render_conversation(map(), String.t() | nil) :: map()
  def render_conversation(conversation, authorization) do
    member_info = Map.get(conversation, :member_info)
    settings = settings_from_member_info(member_info)

    metadata = MediaClient.presign_metadata_urls(conversation.metadata, authorization)

    camelize_keys(%{
      id: conversation.id,
      type: conversation.type,
      name: Map.get(metadata || %{}, "name"),
      external_group_id: conversation.external_group_id,
      metadata: metadata,
      is_active: conversation.is_active,
      is_pinned: Map.get(settings, "is_pinned", false),
      is_archived: Map.get(settings, "is_archived", false),
      is_muted: Map.get(settings, "is_muted", false),
      inserted_at: conversation.inserted_at,
      updated_at: conversation.updated_at
    })
    |> Map.put("unreadCount", Map.get(conversation, :unread_count, 0))
    |> Map.put("lastMessage", render_last_message(Map.get(conversation, :last_message)))
    |> maybe_add_member_ids(conversation)
  end

  @doc """
  Renders the last_message payload, handling nil and binary content safely.
  """
  @spec render_last_message(map() | nil) :: map() | nil
  def render_last_message(nil), do: nil

  def render_last_message(message) do
    camelize_keys(%{
      id: message.id,
      sender_id: message.sender_id,
      content: safe_binary_content(message.content),
      message_type: message.message_type,
      sent_at: message.sent_at,
      is_deleted: message.is_deleted
    })
  end

  @doc """
  Renders content stored as BYTEA safely for JSON (handles non-UTF-8 binaries).
  """
  @spec safe_binary_content(any()) :: String.t() | nil
  def safe_binary_content(nil), do: nil

  def safe_binary_content(content) when is_binary(content) do
    if String.valid?(content), do: content, else: Base.encode64(content)
  end

  def safe_binary_content(content), do: to_string(content)

  @doc """
  Renders a conversation member.
  """
  @spec render_member(map()) :: map()
  def render_member(member) do
    camelize_keys(%{
      user_id: member.user_id,
      role: Map.get(member.settings || %{}, "role", "member"),
      joined_at: member.joined_at,
      is_active: member.is_active
    })
  end

  @doc """
  Renders a conversation including its members list and per-user flags.
  """
  @spec render_conversation_with_members(map(), map() | nil, String.t() | nil) :: map()
  def render_conversation_with_members(conversation, member_info, authorization) do
    member_user_ids = Enum.map(conversation.members, & &1.user_id)

    base =
      conversation
      |> render_conversation(authorization)
      |> Map.put("members", Enum.map(conversation.members, &render_member/1))
      |> Map.put("memberCount", length(conversation.members))
      |> Map.put("memberUserIds", member_user_ids)

    if member_info do
      settings = member_info.settings || %{}

      base
      |> Map.put("isMuted", Map.get(settings, "is_muted", false))
      |> Map.put("isPinned", Map.get(settings, "is_pinned", false))
      |> Map.put("isArchived", Map.get(settings, "is_archived", false))
    else
      base
    end
  end

  @doc """
  Filters a list of conversations by type. `nil` returns all.
  """
  @spec filter_by_type([map()], String.t() | nil) :: [map()]
  def filter_by_type(conversations, nil), do: conversations

  def filter_by_type(conversations, type) do
    Enum.filter(conversations, fn conv -> conv.type == type end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp settings_from_member_info(nil), do: %{}
  defp settings_from_member_info(member_info), do: member_info.settings || %{}

  defp maybe_add_member_ids(rendered, %{type: "direct"} = conversation) do
    member_ids =
      WhisprMessaging.Conversations.list_conversation_members(conversation.id)
      |> Enum.map(& &1.user_id)

    Map.put(rendered, "memberUserIds", member_ids)
  end

  defp maybe_add_member_ids(rendered, _conversation), do: rendered
end
