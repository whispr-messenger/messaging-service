defmodule WhisprMessaging.Conversations do
  @moduledoc """
  The Conversations context - business logic for conversation operations.

  Handles conversation creation, member management, settings,
  and all conversation-related operations.
  """

  import Ecto.Query, warn: false
  alias WhisprMessaging.Repo

  alias WhisprMessaging.Conversations.{Conversation, ConversationMember, ConversationSettings}
  alias WhisprMessaging.Messages.Message

  require Logger

  # Conversation CRUD operations

  @doc """
  Creates a new conversation.
  """
  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a single conversation by id.
  """
  def get_conversation(id) do
    case Repo.get(Conversation, id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  Gets a conversation by id, raising if not found.
  """
  def get_conversation!(id) do
    Repo.get!(Conversation, id)
  end

  @doc """
  Gets a conversation by external group ID.
  """
  def get_conversation_by_external_group_id(external_group_id) do
    case Repo.one(Conversation.by_external_group_id_query(external_group_id)) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  Lists active conversations.
  """
  def list_active_conversations(limit \\ 50) do
    Conversation.active_conversations_query(limit)
    |> Repo.all()
  end

  @doc """
  Updates a conversation.
  """
  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deactivates a conversation (soft delete).
  """
  def deactivate_conversation(%Conversation{} = conversation) do
    conversation
    |> Conversation.deactivate_changeset()
    |> Repo.update()
  end

  @doc """
  Creates a direct conversation between two users.
  """
  def create_direct_conversation(user1_id, user2_id, metadata \\ %{}) do
    Repo.transaction(fn ->
      # Create conversation
      {:ok, conversation} =
        create_conversation(%{
          type: "direct",
          metadata: metadata,
          is_active: true
        })

      # Add both users as members
      {:ok, _member1} = add_conversation_member(conversation.id, user1_id)
      {:ok, _member2} = add_conversation_member(conversation.id, user2_id)

      conversation
    end)
  end

  @doc """
  Creates a group conversation.
  """
  def create_group_conversation(creator_id, member_ids, external_group_id \\ nil, metadata \\ %{}) do
    Repo.transaction(fn ->
      # Create conversation
      {:ok, conversation} =
        create_conversation(%{
          type: "group",
          external_group_id: external_group_id,
          metadata: metadata,
          is_active: true
        })

      # Add creator as member
      {:ok, _creator_member} = add_conversation_member(conversation.id, creator_id)

      # Add other members
      Enum.each(member_ids, fn member_id ->
        {:ok, _member} = add_conversation_member(conversation.id, member_id)
      end)

      conversation
    end)
  end

  # Conversation Member operations

  @doc """
  Adds a member to a conversation.
  """
  def add_conversation_member(conversation_id, user_id, settings \\ nil) do
    member_settings = settings || ConversationMember.default_settings()

    ConversationMember.create_member(conversation_id, user_id, member_settings)
    |> Repo.insert()
  end

  @doc """
  Gets a conversation member by conversation and user ID.
  """
  def get_conversation_member(conversation_id, user_id) do
    Repo.one(ConversationMember.by_conversation_and_user_query(conversation_id, user_id))
  end

  @doc """
  Lists active members of a conversation.
  """
  def list_conversation_members(conversation_id) do
    ConversationMember.active_members_query(conversation_id)
    |> Repo.all()
  end

  @doc """
  Counts active members in a conversation.
  """
  def count_conversation_members(conversation_id) do
    ConversationMember.count_active_members_query(conversation_id)
    |> Repo.one()
  end

  @doc """
  Updates a member's settings.
  """
  def update_member_settings(%ConversationMember{} = member, settings) do
    member
    |> ConversationMember.update_settings_changeset(settings)
    |> Repo.update()
  end

  @doc """
  Marks a member's last read timestamp.
  """
  def mark_member_read(%ConversationMember{} = member, timestamp \\ nil) do
    member
    |> ConversationMember.mark_read_changeset(timestamp)
    |> Repo.update()
  end

  @doc """
  Removes a member from a conversation (deactivates).
  """
  def remove_conversation_member(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      %ConversationMember{} = member ->
        member
        |> ConversationMember.deactivate_changeset()
        |> Repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists conversations for a specific user.
  """
  def list_user_conversations(user_id) do
    conversations =
      ConversationMember.user_conversations_query(user_id)
      |> Repo.all()

    # Enrich with additional data
    enriched_conversations =
      Enum.map(conversations, fn {member, conversation} ->
        unread_count = get_unread_count_for_user(conversation.id, user_id, member.last_read_at)
        last_message = get_last_message(conversation.id)

        conversation
        |> Map.put(:unread_count, unread_count)
        |> Map.put(:last_message, last_message)
        |> Map.put(:member_info, member)
      end)

    {:ok, enriched_conversations}
  end

  @doc """
  Gets conversation summaries for a user.
  """
  def get_conversation_summaries(user_id) do
    # Similar to list_user_conversations but with minimal data
    conversations =
      ConversationMember.user_conversations_query(user_id)
      |> Repo.all()

    summaries =
      Enum.map(conversations, fn {member, conversation} ->
        %{
          id: conversation.id,
          type: conversation.type,
          metadata: conversation.metadata,
          unread_count: get_unread_count_for_user(conversation.id, user_id, member.last_read_at),
          last_activity: conversation.updated_at,
          member_count: count_conversation_members(conversation.id)
        }
      end)

    {:ok, summaries}
  end

  @doc """
  Gets list of conversation IDs where user is active.
  """
  def get_user_active_conversations(user_id) do
    conversation_ids =
      from cm in ConversationMember,
        where: cm.user_id == ^user_id and cm.is_active == true,
        join: c in Conversation,
        on: c.id == cm.conversation_id,
        where: c.is_active == true,
        select: c.id

    {:ok, Repo.all(conversation_ids)}
  end

  @doc """
  Checks if a user is a member of a conversation.
  """
  def member_of_conversation?(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      %ConversationMember{is_active: true} -> true
      _ -> false
    end
  end

  @doc """
  Alias for member_of_conversation? for backwards compatibility.
  """
  def is_conversation_member?(conversation_id, user_id) do
    member_of_conversation?(conversation_id, user_id)
  end

  @doc """
  Lists conversations for a specific user with options.
  """
  def list_user_conversations(user_id, _opts) when is_list(_opts) do
    list_user_conversations(user_id)
  end

  @doc """
  Gets members who haven't read messages since timestamp.
  """
  def get_unread_members(conversation_id, since_timestamp) do
    ConversationMember.unread_members_query(conversation_id, since_timestamp)
    |> Repo.all()
  end

  # Conversation Settings operations

  @doc """
  Gets conversation settings.
  """
  def get_conversation_settings(conversation_id) do
    case Repo.one(ConversationSettings.by_conversation_query(conversation_id)) do
      nil ->
        # Create default settings if none exist
        create_conversation_settings(conversation_id, ConversationSettings.default_settings())

      settings ->
        {:ok, settings}
    end
  end

  @doc """
  Creates conversation settings.
  """
  def create_conversation_settings(conversation_id, settings \\ %{}) do
    ConversationSettings.create_settings(conversation_id, settings)
    |> Repo.insert()
  end

  @doc """
  Updates conversation settings.
  """
  def update_conversation_settings(%ConversationSettings{} = conv_settings, settings) do
    conv_settings
    |> ConversationSettings.update_settings_changeset(settings)
    |> Repo.update()
  end

  # Analytics and metrics

  @doc """
  Gets conversation statistics.
  """
  def get_conversation_stats(conversation_id) do
    member_count = count_conversation_members(conversation_id)

    message_count =
      from(m in Message,
        where: m.conversation_id == ^conversation_id and m.is_deleted == false,
        select: count(m.id)
      )
      |> Repo.one()

    last_activity =
      from(m in Message,
        where: m.conversation_id == ^conversation_id and m.is_deleted == false,
        select: max(m.sent_at),
        limit: 1
      )
      |> Repo.one()

    %{
      member_count: member_count,
      message_count: message_count,
      last_activity: last_activity
    }
  end

  @doc """
  Gets conversation activity metrics for a time period.
  """
  def get_conversation_activity(conversation_id, from_date, to_date) do
    query =
      from m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.sent_at >= ^from_date and m.sent_at <= ^to_date,
        where: m.is_deleted == false,
        group_by: [fragment("date_trunc('day', ?)", m.sent_at)],
        select: %{
          date: fragment("date_trunc('day', ?)", m.sent_at),
          message_count: count(m.id),
          unique_senders: count(m.sender_id, :distinct)
        },
        order_by: [asc: fragment("date_trunc('day', ?)", m.sent_at)]

    Repo.all(query)
  end

  # Helper functions

  defp get_unread_count_for_user(conversation_id, user_id, last_read_at) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.sender_id != ^user_id,
      where: m.is_deleted == false,
      where: is_nil(^last_read_at) or m.sent_at > ^last_read_at,
      select: count(m.id)
    )
    |> Repo.one()
  end

  defp get_last_message(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.is_deleted == false,
      order_by: [desc: m.sent_at],
      limit: 1
    )
    |> Repo.one()
  end

  # Conversation discovery and search

  @doc """
  Searches conversations by metadata.
  """
  def search_conversations(search_term, limit \\ 20) do
    search_pattern = "%#{search_term}%"

    query =
      from c in Conversation,
        where: c.is_active == true,
        where: ilike(fragment("?::text", c.metadata), ^search_pattern),
        order_by: [desc: c.updated_at],
        limit: ^limit

    Repo.all(query)
  end

  @doc """
  Gets a conversation with members preloaded.
  """
  def get_conversation_with_members(conversation_id) do
    case Repo.one(Conversation.with_members_query(conversation_id)) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  Finds or creates a direct conversation between two users.
  """
  def find_or_create_direct_conversation(user1_id, user2_id) do
    # Try to find existing direct conversation
    query =
      from c in Conversation,
        join: cm1 in ConversationMember,
        on: cm1.conversation_id == c.id,
        join: cm2 in ConversationMember,
        on: cm2.conversation_id == c.id,
        where: c.type == "direct" and c.is_active == true,
        where: cm1.user_id == ^user1_id and cm1.is_active == true,
        where: cm2.user_id == ^user2_id and cm2.is_active == true,
        where: cm1.user_id != cm2.user_id

    case Repo.one(query) do
      nil ->
        # Create new conversation
        create_direct_conversation(user1_id, user2_id)

      conversation ->
        {:ok, conversation}
    end
  end
end
