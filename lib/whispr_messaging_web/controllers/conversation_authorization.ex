defmodule WhisprMessagingWeb.ConversationAuthorization do
  @moduledoc """
  Authorization helpers extracted from `ConversationController` so the
  permission rules (membership / admin role / delete eligibility) can be
  unit-tested in isolation. External REST contract is unchanged.
  """

  alias WhisprMessaging.Conversations

  @doc """
  Checks if a user appears in the preloaded `:members` list of a conversation.

  Used after `get_conversation_with_members/2` so we don't hit the DB twice.
  """
  @spec user_is_member?(map(), String.t() | nil) :: boolean()
  def user_is_member?(_conversation, nil), do: false

  def user_is_member?(conversation, user_id) do
    case Map.get(conversation, :members) do
      members when is_list(members) ->
        Enum.any?(members, fn member ->
          member.user_id == user_id and Map.get(member, :is_active, true) == true
        end)

      _ ->
        false
    end
  end

  @doc """
  Returns true when `user_id` is an active member of `conversation_id` (DB
  lookup). Inactive (removed/left) members are rejected so authorization
  cannot survive a member removal.
  """
  @spec member?(String.t(), String.t() | nil) :: boolean()
  def member?(_conversation_id, nil), do: false

  def member?(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      %{is_active: true} -> true
      _ -> false
    end
  end

  @doc """
  Returns true when `user_id` has `admin` or `owner` role on `conversation`
  AND is still an active member. Anonymous callers (nil) and inactive
  members are rejected.
  """
  @spec can_manage_members?(map(), String.t() | nil) :: boolean()
  def can_manage_members?(_conversation, nil), do: false

  def can_manage_members?(conversation, user_id) do
    case Conversations.get_conversation_member(conversation.id, user_id) do
      %{is_active: true, settings: settings} ->
        role = Map.get(settings || %{}, "role", "member")
        role in ["admin", "owner"]

      _ ->
        false
    end
  end

  @doc """
  WHISPR-841: deleting a group requires admin role; direct conversations have
  no admin concept, so any active member may deactivate the thread.
  """
  @spec can_delete_conversation?(map(), String.t() | nil) :: boolean()
  def can_delete_conversation?(_conversation, nil), do: false

  def can_delete_conversation?(%{type: "direct"} = conversation, user_id),
    do: member?(conversation.id, user_id)

  def can_delete_conversation?(conversation, user_id),
    do: can_manage_members?(conversation, user_id)

  @doc """
  Returns true when `user_id` is an active member with admin role on the
  conversation identified by `conversation_id` (DB lookup).
  """
  @spec admin?(String.t(), String.t() | nil) :: boolean()
  def admin?(_conversation_id, nil), do: false

  def admin?(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      %{is_active: true} = member ->
        Conversations.member_role(member) == "admin"

      _ ->
        false
    end
  end

  @doc """
  Returns true when `user_id` is an active member of `conversation_id`.
  Identical to `member?/2` but with an explicit name used at member
  controller call sites where active-state is the central concern.
  """
  @spec active_member?(String.t(), String.t() | nil) :: boolean()
  def active_member?(_conversation_id, nil), do: false

  def active_member?(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      %{is_active: true} -> true
      _ -> false
    end
  end
end
