defmodule WhisprMessaging.Conversations do
  @moduledoc """
  The Conversations context - business logic for conversation operations.

  Handles conversation creation, member management, settings,
  and all conversation-related operations.
  """

  import Ecto.Query, warn: false
  alias WhisprMessaging.Repo

  alias WhisprMessaging.Conversations.{
    BlockCache,
    Conversation,
    ConversationMember,
    ConversationSettings
  }

  alias WhisprMessaging.Messages.Message
  alias WhisprMessaging.Services.UserService

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
    if user1_id == user2_id do
      changeset =
        %Conversation{}
        |> Conversation.changeset(%{})
        |> Ecto.Changeset.add_error(:base, "Cannot create conversation with yourself")

      {:error, changeset}
    else
      do_create_direct_conversation(user1_id, user2_id, metadata)
    end
  end

  defp do_create_direct_conversation(user1_id, user2_id, metadata) do
    # Check if user exists and if there are blocks
    with {:ok, true} <- UserService.check_user_exists(user2_id),
         {:ok, false} <- UserService.check_user_blocked(user2_id, user1_id),
         {:ok, false} <- UserService.check_user_blocked(user1_id, user2_id) do
      find_or_create_direct_conversation(user1_id, user2_id, metadata)
    else
      {:ok, false} -> {:error, :user_not_found}
      {:ok, true} -> {:error, :blocked}
      error -> error
    end
  end

  defp find_or_create_direct_conversation(user1_id, user2_id, metadata) do
    case find_direct_conversation(user1_id, user2_id) do
      nil ->
        Repo.transaction(fn ->
          {:ok, conversation} =
            create_conversation(%{
              type: "direct",
              metadata: metadata,
              is_active: true
            })

          {:ok, _member1} = add_conversation_member(conversation.id, user1_id)
          {:ok, _member2} = add_conversation_member(conversation.id, user2_id)

          conversation
        end)

      %{is_active: true} = conversation ->
        {:ok, conversation}

      conversation ->
        update_conversation(conversation, %{is_active: true})
    end
  end

  @doc """
  Finds a direct conversation between two users (active or inactive).
  """
  def find_direct_conversation(user1_id, user2_id) do
    query =
      from c in Conversation,
        join: m1 in ConversationMember,
        on: m1.conversation_id == c.id,
        join: m2 in ConversationMember,
        on: m2.conversation_id == c.id,
        where: c.type == "direct",
        where: m1.user_id == ^user1_id,
        where: m2.user_id == ^user2_id

    Repo.one(query)
  end

  @doc """
  Creates a group conversation.
  """
  def create_group_conversation(
        creator_id,
        member_ids,
        name,
        external_group_id \\ nil,
        metadata \\ %{}
      ) do
    Repo.transaction(fn ->
      group_metadata = Map.put(metadata, "name", name)

      with {:ok, conversation} <-
             create_conversation(%{
               type: "group",
               external_group_id: external_group_id,
               metadata: group_metadata,
               is_active: true
             }),
           {:ok, _creator_member} <- add_creator_as_admin(conversation.id, creator_id),
           :ok <- add_members(conversation.id, member_ids) do
        conversation
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp add_creator_as_admin(conversation_id, creator_id) do
    creator_settings = ConversationMember.default_settings() |> Map.put("role", "admin")
    add_conversation_member(conversation_id, creator_id, creator_settings)
  end

  defp add_members(_conversation_id, []), do: :ok

  defp add_members(conversation_id, member_ids) do
    Enum.reduce_while(member_ids, :ok, fn member_id, :ok ->
      case add_conversation_member(conversation_id, member_id) do
        {:ok, _member} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
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
  WHISPR-1364: renvoie la map des relations de blocage entre membres
  d'une conversation, pour filtrer le broadcast cote channel.

  Forme : `%{user_id => MapSet.t([blocked_user_id, ...])}`. La cle est
  un destinataire potentiel ; la valeur l'ensemble des autres membres
  qu'il considere bloques (ou qui l'ont bloque - relation symetrique).
  Quand un message provient d'un sender dans cet ensemble, on doit
  skipper le broadcast vers ce destinataire.

  Cache 60s par conversation_id (cf `BlockCache`). Sur erreur transitoire
  user-service, on fail-open : pas de filtre, l'app messaging ne casse
  pas si user-service est down.
  """
  def get_blocks_for_conversation(conversation_id) do
    member_ids =
      conversation_id
      |> list_conversation_members()
      |> Enum.map(& &1.user_id)

    BlockCache.get_for_conversation(conversation_id, member_ids)
  end

  @doc """
  Lists active member user_ids for several conversations in a single query.

  Retourne un map `%{conversation_id => [user_id, ...]}`. Permet d'eviter le
  N+1 quand on rend une liste de conversations directes (WHISPR-848).
  """
  def list_members_for_conversations([]), do: %{}

  def list_members_for_conversations(conversation_ids) when is_list(conversation_ids) do
    from(m in ConversationMember,
      where: m.conversation_id in ^conversation_ids,
      where: m.is_active == true,
      order_by: [asc: m.joined_at],
      select: {m.conversation_id, m.user_id}
    )
    |> Repo.all()
    |> Enum.group_by(fn {conv_id, _} -> conv_id end, fn {_, user_id} -> user_id end)
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

  # ---------------------------------------------------------------------------
  # Per-user conversation settings (WHISPR-467)
  # ---------------------------------------------------------------------------

  # Keys that a member can read/write via the public settings endpoint.
  # Internal keys (is_pinned, is_archived, role) are excluded from this API.
  @member_settings_allowlist ~w(
    notifications
    sound_enabled
    desktop_notifications
    mobile_notifications
    mention_notifications
    is_muted
    custom_name
  )

  @doc """
  Gets the per-user settings for a conversation member.

  Returns `{:ok, settings_map}` or `{:error, :not_member}`.
  """
  def get_conversation_member_settings(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      %ConversationMember{is_active: true, settings: settings} ->
        public_settings = Map.take(settings || %{}, @member_settings_allowlist)

        base_defaults =
          Map.take(ConversationMember.default_settings(), @member_settings_allowlist)

        defaults = Map.merge(base_defaults, %{"is_muted" => false, "custom_name" => nil})

        {:ok, Map.merge(defaults, public_settings)}

      _ ->
        {:error, :not_member}
    end
  end

  @doc """
  Updates the per-user settings for a conversation member (partial update).

  Only keys in the allowlist are accepted; unrecognised keys are ignored.
  Returns `{:ok, member}` or `{:error, :not_member}`.
  """
  def update_conversation_member_settings(conversation_id, user_id, attrs) do
    case get_conversation_member(conversation_id, user_id) do
      %ConversationMember{is_active: true} = member ->
        # Only merge allowed keys; preserve protected keys (role, is_pinned, etc.)
        allowed_updates = Map.take(attrs, @member_settings_allowlist)
        new_settings = Map.merge(member.settings || %{}, allowed_updates)

        member
        |> ConversationMember.update_settings_changeset(new_settings)
        |> Repo.update()

      _ ->
        {:error, :not_member}
    end
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
  WHISPR-1304: rewind `last_read_at` du member a `before` (typiquement
  juste avant le `sent_at` du message qu'on remarque comme non-lu).
  Si `before` est `nil`, on reset le champ a nil pour que toutes les
  messages comptent comme non-lus.
  """
  def mark_member_unread(%ConversationMember{} = member, before \\ nil) do
    member
    |> ConversationMember.rewind_read_changeset(before)
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

  # ---------------------------------------------------------------------------
  # Group member role management (WHISPR-965)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the role ("admin" or "member") stored in a member's settings.
  """
  def member_role(%ConversationMember{settings: settings}) do
    Map.get(settings || %{}, "role", "member")
  end

  def member_role(nil), do: nil

  @doc """
  Lists active admin members for a conversation.
  """
  def list_admin_members(conversation_id) do
    conversation_id
    |> list_conversation_members()
    |> Enum.filter(fn m -> member_role(m) == "admin" end)
  end

  @doc """
  Updates a member's role. Only `"admin"` and `"member"` are accepted.
  """
  def set_member_role(%ConversationMember{} = member, new_role)
      when new_role in ["admin", "member"] do
    new_settings = Map.put(member.settings || %{}, "role", new_role)

    member
    |> ConversationMember.update_settings_changeset(new_settings)
    |> Repo.update()
  end

  def set_member_role(_member, _role), do: {:error, :invalid_role}

  @doc """
  Makes a user leave a conversation.

  Handles the auto-promote rule: when the leaving user is the only admin and
  at least one non-admin member remains, the oldest non-admin member is
  promoted to admin before the leaver is deactivated. When the leaver is the
  last active member, the conversation is deactivated.

  Returns `{:ok, %{member: member, auto_promoted: member_or_nil,
  conversation_deactivated: boolean}}` on success.
  """
  def leave_conversation(conversation_id, user_id) do
    Repo.transaction(fn ->
      # lock + re-query pour eviter promote spurious sur 2 admins quit concurrents.
      # On lock toutes les rows actives de la conversation : serialise les
      # leave concurrents pour qu'une seule tx voie l'etat post-commit de
      # l'autre (apres release du lock).
      lock_query =
        from m in ConversationMember,
          where: m.conversation_id == ^conversation_id and m.is_active == true,
          order_by: [asc: m.joined_at],
          lock: "FOR UPDATE"

      with {:ok, conversation} <- get_conversation(conversation_id),
           members <- Repo.all(lock_query),
           %ConversationMember{is_active: true} = member <-
             Enum.find(members, fn m -> m.user_id == user_id end) do
        role = member_role(member)

        auto_promoted =
          if role == "admin" do
            maybe_auto_promote(members, user_id)
          else
            nil
          end

        {:ok, deactivated} =
          member
          |> ConversationMember.deactivate_changeset()
          |> Repo.update()

        conversation_deactivated = maybe_deactivate_if_empty(conversation, members, user_id)

        %{
          member: deactivated,
          auto_promoted: auto_promoted,
          conversation_deactivated: conversation_deactivated
        }
      else
        {:error, :not_found} -> Repo.rollback(:conversation_not_found)
        nil -> Repo.rollback(:not_member)
      end
    end)
  end

  # If the leaver is the only admin, promote the oldest remaining plain member.
  defp maybe_auto_promote(members, leaver_user_id) do
    admins = Enum.filter(members, fn m -> member_role(m) == "admin" end)

    if match?([%ConversationMember{user_id: ^leaver_user_id}], admins) do
      promote_oldest_remaining(members, leaver_user_id)
    else
      nil
    end
  end

  defp promote_oldest_remaining(members, leaver_user_id) do
    candidate =
      members
      |> Enum.reject(fn m -> m.user_id == leaver_user_id end)
      |> Enum.filter(fn m -> m.is_active and member_role(m) == "member" end)
      |> Enum.sort_by(& &1.joined_at, DateTime)
      |> List.first()

    with %ConversationMember{} = c <- candidate,
         {:ok, promoted} <- set_member_role(c, "admin") do
      promoted
    else
      _ -> nil
    end
  end

  defp maybe_deactivate_if_empty(conversation, members, user_id) do
    case Enum.reject(members, fn m -> m.user_id == user_id end) do
      [] ->
        {:ok, _} =
          conversation
          |> Conversation.deactivate_changeset()
          |> Repo.update()

        true

      _ ->
        false
    end
  end

  @doc """
  Lists conversations for a specific user.
  """
  def list_user_conversations(user_id, opts \\ [])

  def list_user_conversations(user_id, limit) when is_integer(limit) do
    list_user_conversations(user_id, limit: limit)
  end

  def list_user_conversations(user_id, opts) do
    limit = Keyword.get(opts, :limit, 50)

    conversations =
      ConversationMember.user_conversations_query(user_id)
      |> limit(^limit)
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

    enriched_conversations
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
  def conversation_member?(conversation_id, user_id) do
    member_of_conversation?(conversation_id, user_id)
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

  def update_conversation_settings(conversation_id, settings) when is_binary(conversation_id) do
    case get_conversation_settings(conversation_id) do
      {:ok, conv_settings} ->
        update_conversation_settings(conv_settings, settings)

      error ->
        error
    end
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
    query =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.sender_id != ^user_id,
        where: m.is_deleted == false
      )

    query =
      if last_read_at do
        from m in query, where: m.sent_at > ^last_read_at
      else
        query
      end

    from(m in query, select: count(m.id))
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
  Searches the authenticated user's conversations by name or participant user_id.

  The `q` parameter is matched case-insensitively against:
  - the group conversation name stored in `metadata->>'name'`
  - the `user_id` of any other member in the conversation (exact match)

  Returns a list of conversations enriched with `:member_info` (the calling
  user's `ConversationMember` record) so that `render_conversation/1` in the
  controller can expose per-user flags like `is_pinned`, `is_archived`, etc.
  """
  def search_user_conversations(user_id, query_term, opts \\ []) do
    limit = max(Keyword.get(opts, :limit, 20), 1)
    search_pattern = "%#{query_term}%"

    # Conversations the user belongs to, filtered by group name match
    by_name =
      from m in ConversationMember,
        where: m.user_id == ^user_id and m.is_active == true,
        join: c in Conversation,
        on: c.id == m.conversation_id and c.is_active == true,
        where: c.type == "group",
        where: ilike(fragment("(?->>'name')", c.metadata), ^search_pattern),
        order_by: [desc: c.updated_at],
        limit: ^limit,
        select: {m, c}

    # Conversations the user belongs to where another participant matches the query
    by_participant =
      from m in ConversationMember,
        where: m.user_id == ^user_id and m.is_active == true,
        join: c in Conversation,
        on: c.id == m.conversation_id and c.is_active == true,
        join: other in ConversationMember,
        on:
          other.conversation_id == c.id and other.user_id != ^user_id and
            other.is_active == true,
        where: other.user_id == ^query_term,
        order_by: [desc: c.updated_at],
        limit: ^limit,
        select: {m, c}

    name_results = Repo.all(by_name)

    # Only query by participant when the term is a valid UUID — the user_id
    # field is a binary_id and Ecto raises a CastError otherwise.
    participant_results =
      if valid_uuid?(query_term) do
        Repo.all(by_participant)
      else
        []
      end

    (name_results ++ participant_results)
    |> Enum.uniq_by(fn {_m, c} -> c.id end)
    |> Enum.sort_by(fn {_m, c} -> c.updated_at end, {:desc, NaiveDateTime})
    |> Enum.take(limit)
    |> Enum.map(fn {member, conversation} ->
      Map.put(conversation, :member_info, member)
    end)
  end

  defp valid_uuid?(str) when is_binary(str) do
    case Ecto.UUID.cast(str) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  @doc """
  Gets a conversation with members preloaded.
  """
  def get_conversation_with_members(conversation_id, user_id \\ nil) do
    case Repo.one(Conversation.with_members_query(conversation_id)) do
      nil ->
        {:error, :not_found}

      conversation ->
        member_info =
          if user_id do
            get_conversation_member(conversation_id, user_id)
          end

        {:ok, Map.put(conversation, :member_info, member_info)}
    end
  end

  # ---------------------------------------------------------------------------
  # Conversation pin / unpin (WHISPR-465)
  # ---------------------------------------------------------------------------

  @max_pinned_conversations 5

  @doc "Returns the maximum number of conversations a user can pin."
  def max_pinned_conversations, do: @max_pinned_conversations

  @doc """
  Pins a conversation for a user.

  Returns `{:ok, member}` on success, `{:error, :not_member}` if the user is
  not an active member, `{:error, :already_pinned}` if already pinned, or
  `{:error, :pin_limit_reached}` when the user already has
  #{@max_pinned_conversations} pinned conversations.
  """
  def pin_conversation(conversation_id, user_id) do
    lock_key = :erlang.phash2(user_id, 2_147_483_647)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

      conversation_id
      |> get_conversation_member(user_id)
      |> do_pin_member(user_id)
    end)
    |> unwrap_transaction_result()
  end

  defp do_pin_member(%ConversationMember{is_active: true} = member, user_id) do
    settings = member.settings || %{}

    cond do
      Map.get(settings, "is_pinned", false) ->
        Repo.rollback(:already_pinned)

      count_pinned_conversations(user_id) >= @max_pinned_conversations ->
        Repo.rollback(:pin_limit_reached)

      true ->
        apply_pin_settings(member, settings)
    end
  end

  defp do_pin_member(_member, _user_id), do: Repo.rollback(:not_member)

  defp apply_pin_settings(member, settings) do
    new_settings = Map.put(settings, "is_pinned", true)

    case member
         |> ConversationMember.update_settings_changeset(new_settings)
         |> Repo.update() do
      {:ok, updated_member} -> updated_member
      {:error, changeset} -> Repo.rollback({:changeset, changeset})
    end
  end

  defp unwrap_transaction_result({:ok, result}), do: {:ok, result}
  defp unwrap_transaction_result({:error, {:changeset, cs}}), do: {:error, cs}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  @doc """
  Unpins a conversation for a user.

  Returns `{:ok, member}` on success, `{:error, :not_member}` if the user is
  not an active member, or `{:error, :not_pinned}` if the conversation is not
  currently pinned.
  """
  def unpin_conversation(conversation_id, user_id) do
    lock_key = :erlang.phash2(user_id, 2_147_483_647)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

      conversation_id
      |> get_conversation_member(user_id)
      |> do_unpin_member()
    end)
    |> unwrap_transaction_result()
  end

  defp do_unpin_member(%ConversationMember{is_active: true} = member) do
    settings = member.settings || %{}

    if Map.get(settings, "is_pinned", false) do
      apply_unpin_settings(member, settings)
    else
      Repo.rollback(:not_pinned)
    end
  end

  defp do_unpin_member(_member), do: Repo.rollback(:not_member)

  defp apply_unpin_settings(member, settings) do
    new_settings = Map.put(settings, "is_pinned", false)

    case member
         |> ConversationMember.update_settings_changeset(new_settings)
         |> Repo.update() do
      {:ok, updated_member} -> updated_member
      {:error, changeset} -> Repo.rollback({:changeset, changeset})
    end
  end

  defp count_pinned_conversations(user_id) do
    from(m in ConversationMember,
      where: m.user_id == ^user_id,
      where: m.is_active == true,
      where: fragment("(?->>'is_pinned')::boolean = true", m.settings)
    )
    |> Repo.aggregate(:count, :id)
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

  # ---------------------------------------------------------------------------
  # Conversation archive / unarchive (WHISPR-466)
  # ---------------------------------------------------------------------------

  @doc """
  Archives a conversation for a user.

  Returns `{:ok, member}` on success, `{:error, :not_member}` if the user is
  not an active member, `{:error, :already_archived}` if already archived, or
  `{:error, :conversation_inactive}` if the conversation has been soft-deleted.
  """
  def archive_conversation(conversation_id, user_id) do
    lock_key = :erlang.phash2(user_id, 2_147_483_647)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

      conversation_id
      |> get_conversation_member(user_id)
      |> do_archive_member(conversation_id)
    end)
    |> unwrap_transaction_result()
  end

  defp do_archive_member(%ConversationMember{is_active: true} = member, conversation_id) do
    settings = member.settings || %{}

    cond do
      not conversation_active?(conversation_id) ->
        Repo.rollback(:conversation_inactive)

      Map.get(settings, "is_archived", false) ->
        Repo.rollback(:already_archived)

      true ->
        apply_archive_settings(member, settings, true)
    end
  end

  defp do_archive_member(_member, _conversation_id), do: Repo.rollback(:not_member)

  @doc """
  Unarchives a conversation for a user.

  Returns `{:ok, member}` on success, `{:error, :not_member}` if the user is
  not an active member, `{:error, :not_archived}` if the conversation is not
  currently archived, or `{:error, :conversation_inactive}` if the conversation
  has been soft-deleted.
  """
  def unarchive_conversation(conversation_id, user_id) do
    lock_key = :erlang.phash2(user_id, 2_147_483_647)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

      conversation_id
      |> get_conversation_member(user_id)
      |> do_unarchive_member(conversation_id)
    end)
    |> unwrap_transaction_result()
  end

  defp do_unarchive_member(%ConversationMember{is_active: true} = member, conversation_id) do
    settings = member.settings || %{}

    cond do
      not conversation_active?(conversation_id) ->
        Repo.rollback(:conversation_inactive)

      not Map.get(settings, "is_archived", false) ->
        Repo.rollback(:not_archived)

      true ->
        apply_archive_settings(member, settings, false)
    end
  end

  defp do_unarchive_member(_member, _conversation_id), do: Repo.rollback(:not_member)

  defp apply_archive_settings(member, settings, archived?) do
    new_settings = Map.put(settings, "is_archived", archived?)

    case member
         |> ConversationMember.update_settings_changeset(new_settings)
         |> Repo.update() do
      {:ok, updated_member} -> updated_member
      {:error, changeset} -> Repo.rollback({:changeset, changeset})
    end
  end

  defp conversation_active?(conversation_id) do
    Repo.exists?(from c in Conversation, where: c.id == ^conversation_id and c.is_active == true)
  end

  @doc """
  Lists archived conversations for a user.

  Each conversation is enriched with `:member_info`, `:last_message`, and
  `:unread_count` so the listing can be rendered without follow-up queries.
  Enrichment is batched to avoid N+1 even at the maximum page size of 100.

  Accepts the following options:

    * `:limit` (default: 50) — page size
    * `:offset` (default: 0) — number of rows to skip
  """
  def list_archived_conversations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from m in ConversationMember,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.user_id == ^user_id,
        where: m.is_active == true,
        where: c.is_active == true,
        where: fragment("(?->>'is_archived')::boolean = true", m.settings),
        order_by: [desc: c.updated_at, desc: c.id],
        limit: ^limit,
        offset: ^offset,
        select: {m, c}

    results = Repo.all(query)
    conversation_ids = Enum.map(results, fn {_m, c} -> c.id end)

    last_messages = batch_last_messages(conversation_ids)
    unread_counts = batch_unread_counts(results, user_id)

    Enum.map(results, fn {member, conversation} ->
      conversation
      |> Map.put(:member_info, member)
      |> Map.put(:last_message, Map.get(last_messages, conversation.id))
      |> Map.put(:unread_count, Map.get(unread_counts, conversation.id, 0))
    end)
  end

  # Loads the most recent non-deleted message for each conversation in one
  # query, using `DISTINCT ON (conversation_id)` so PostgreSQL keeps only the
  # newest row per conversation.
  defp batch_last_messages([]), do: %{}

  defp batch_last_messages(conversation_ids) do
    # `sent_at` is stored at second precision, so two messages inserted in the
    # same second can collide. Adding `inserted_at` and `id` as tiebreakers
    # keeps the "most recent" pick deterministic.
    query =
      from m in Message,
        where: m.conversation_id in ^conversation_ids,
        where: m.is_deleted == false,
        distinct: [asc: m.conversation_id],
        order_by: [asc: m.conversation_id, desc: m.sent_at, desc: m.inserted_at, desc: m.id]

    query
    |> Repo.all()
    |> Map.new(fn message -> {message.conversation_id, message} end)
  end

  # Counts unread messages per conversation in a single aggregated query.
  # Joining `conversation_members` lets PostgreSQL apply each member's own
  # `last_read_at` as the cutoff (NULL means everything counts as unread)
  # without round-tripping per conversation.
  defp batch_unread_counts([], _user_id), do: %{}

  defp batch_unread_counts(member_conversations, user_id) do
    conversation_ids = Enum.map(member_conversations, fn {_m, c} -> c.id end)

    query =
      from m in Message,
        join: cm in ConversationMember,
        on: cm.conversation_id == m.conversation_id and cm.user_id == ^user_id,
        where: m.conversation_id in ^conversation_ids,
        where: m.sender_id != ^user_id,
        where: m.is_deleted == false,
        where: is_nil(cm.last_read_at) or m.sent_at > cm.last_read_at,
        group_by: m.conversation_id,
        select: {m.conversation_id, count(m.id)}

    query
    |> Repo.all()
    |> Map.new()
  end
end
