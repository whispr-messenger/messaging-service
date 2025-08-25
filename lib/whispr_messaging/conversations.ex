defmodule WhisprMessaging.Conversations do
  @moduledoc """
  Contexte pour la gestion des conversations selon la documentation system_design.md
  """

  import Ecto.Query, warn: false
  alias WhisprMessaging.Repo

  alias WhisprMessaging.Conversations.{
    Conversation, 
    ConversationMember, 
    ConversationSettings
  }
  # alias WhisprMessaging.Messages.Message (utilisé dans les requêtes via string)

  ## Conversations

  @doc """
  Récupère toutes les conversations actives d'un utilisateur
  """
  def list_user_conversations(user_id) do
    from(c in Conversation,
      join: cm in ConversationMember, on: c.id == cm.conversation_id,
      where: cm.user_id == ^user_id and cm.is_active == true and c.is_active == true,
      preload: [:settings],
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @doc """
  Récupère une conversation par son ID
  """
  def get_conversation!(id), do: Repo.get!(Conversation, id)

  @doc """
  Récupère une conversation avec ses membres
  """
  def get_conversation_with_members!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:members, :settings])
  end

  @doc """
  Crée une conversation directe entre deux utilisateurs
  """
  def create_direct_conversation(user_id1, user_id2, metadata \\ %{}) do
    # Vérifier si la conversation existe déjà
    case find_direct_conversation(user_id1, user_id2) do
      nil ->
        # Créer une nouvelle conversation via transaction
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:conversation, 
            Conversation.direct_changeset(%{metadata: metadata}))
        |> Ecto.Multi.insert(:member1, fn %{conversation: conv} ->
            ConversationMember.add_member_changeset(%{
              conversation_id: conv.id,
              user_id: user_id1
            })
          end)
        |> Ecto.Multi.insert(:member2, fn %{conversation: conv} ->
            ConversationMember.add_member_changeset(%{
              conversation_id: conv.id,
              user_id: user_id2
            })
          end)
        |> Ecto.Multi.insert(:settings, fn %{conversation: conv} ->
            ConversationSettings.default_changeset(conv.id)
          end)
        |> Repo.transaction()
        |> case do
            {:ok, %{conversation: conversation}} -> {:ok, conversation}
            {:error, _, changeset, _} -> {:error, changeset}
          end
          
      conversation ->
        {:ok, conversation}
    end
  end

  @doc """
  Crée une conversation de groupe
  """
  def create_group_conversation(external_group_id, creator_user_id, metadata \\ %{}) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:conversation, 
        Conversation.group_changeset(%{
          external_group_id: external_group_id,
          metadata: metadata
        }))
    |> Ecto.Multi.insert(:creator_member, fn %{conversation: conv} ->
        ConversationMember.add_member_changeset(%{
          conversation_id: conv.id,
          user_id: creator_user_id
        })
      end)
    |> Ecto.Multi.insert(:settings, fn %{conversation: conv} ->
        ConversationSettings.default_changeset(conv.id)
      end)
    |> Repo.transaction()
    |> case do
        {:ok, %{conversation: conversation}} -> {:ok, conversation}
        {:error, _, changeset, _} -> {:error, changeset}
      end
  end

  @doc """
  Met à jour une conversation
  """
  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Désactive une conversation (soft delete)
  """
  def deactivate_conversation(%Conversation{} = conversation) do
    update_conversation(conversation, %{is_active: false})
  end

  @doc """
  Trouve une conversation directe entre deux utilisateurs
  """
  def find_direct_conversation(user_id1, user_id2) do
    # Chercher une conversation directe avec exactement ces deux utilisateurs
    from(c in Conversation,
      join: cm1 in ConversationMember, on: c.id == cm1.conversation_id,
      join: cm2 in ConversationMember, on: c.id == cm2.conversation_id,
      where: c.type == "direct" and c.is_active == true and
             cm1.user_id == ^user_id1 and cm1.is_active == true and
             cm2.user_id == ^user_id2 and cm2.is_active == true and
             cm1.id != cm2.id,
      group_by: c.id,
      having: count(cm1.id) == 2  # Exactement 2 membres
    )
    |> Repo.one()
  end

  ## Members

  @doc """
  Ajoute un membre à une conversation
  """
  def add_member_to_conversation(conversation_id, user_id) do
    ConversationMember.add_member_changeset(%{
      conversation_id: conversation_id,
      user_id: user_id
    })
    |> Repo.insert()
  end

  @doc """
  Retire un membre d'une conversation
  """
  def remove_member_from_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :not_found}
      member ->
        member
        |> ConversationMember.deactivate_changeset()
        |> Repo.update()
    end
  end

  @doc """
  Récupère un membre de conversation
  """
  def get_conversation_member(conversation_id, user_id) do
    from(cm in ConversationMember,
      where: cm.conversation_id == ^conversation_id and 
             cm.user_id == ^user_id and 
             cm.is_active == true
    )
    |> Repo.one()
  end

  @doc """
  Vérifie si un utilisateur est membre d'une conversation
  """
  def is_member?(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Marque les messages comme lus pour un utilisateur
  """
  def mark_conversation_as_read(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :not_found}
      member ->
        member
        |> ConversationMember.mark_read_changeset()
        |> Repo.update()
    end
  end

  ## Settings

  @doc """
  Récupère les paramètres d'une conversation
  """
  def get_conversation_settings(conversation_id) do
    case Repo.get_by(ConversationSettings, conversation_id: conversation_id) do
      nil ->
        # Créer les paramètres par défaut s'ils n'existent pas
        ConversationSettings.default_changeset(conversation_id)
        |> Repo.insert()
        
      settings ->
        {:ok, settings}
    end
  end

  @doc """
  Met à jour un paramètre de conversation
  """
  def update_conversation_setting(conversation_id, key, value) do
    case get_conversation_settings(conversation_id) do
      {:ok, settings} ->
        settings
        |> ConversationSettings.update_setting_changeset(key, value)
        |> Repo.update()
        
      error ->
        error
    end
  end

  @doc """
  Met à jour plusieurs paramètres de conversation
  """
  def update_conversation_settings(conversation_id, new_settings) do
    case get_conversation_settings(conversation_id) do
      {:ok, settings} ->
        settings
        |> ConversationSettings.update_settings_changeset(new_settings)
        |> Repo.update()
        
      error ->
        error
    end
  end

  ## Additional functions for compatibility

  @doc """
  Récupère une conversation par son ID (version safe)
  """
  def get_conversation(id) do
    case Repo.get(Conversation, id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc """
  Crée une conversation générique
  """
  def create_conversation(attrs) do
    case attrs do
      %{type: "direct", participants: [user_id1, user_id2]} ->
        create_direct_conversation(user_id1, user_id2, Map.get(attrs, :metadata, %{}))
      
      %{type: "group", external_group_id: group_id, creator_id: creator_id} ->
        create_group_conversation(group_id, creator_id, Map.get(attrs, :metadata, %{}))
      
      _ ->
        {:error, :invalid_conversation_attrs}
    end
  end

  @doc """
  Ajoute un membre à une conversation (alias pour compatibilité)
  """
  def add_conversation_member(attrs) do
    add_member_to_conversation(attrs.conversation_id, attrs.user_id)
  end

  @doc """
  Récupère la dernière activité d'une conversation
  """
  def get_last_activity(conversation_id) do
    from(c in Conversation,
      where: c.id == ^conversation_id,
      select: c.updated_at
    )
    |> Repo.one()
  end

  @doc """
  Liste les conversations avec des politiques de rétention
  """
  def list_conversations_with_retention_policies do
    from(c in Conversation,
      join: cs in ConversationSettings, on: c.id == cs.conversation_id,
      where: not is_nil(fragment("? -> 'retention_days'", cs.settings)),
      select: %{
        conversation_id: c.id,
        retention_days: fragment("(? -> 'retention_days')::int", cs.settings)
      }
    )
    |> Repo.all()
  end

  ## Statistics

  @doc """
  Compte le nombre total de conversations
  """
  def count_total_conversations do
    from(c in Conversation,
      where: c.is_active == true,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Compte les conversations actives depuis une date
  """
  def count_active_since(since_datetime) do
    from(c in Conversation,
      where: c.is_active == true and c.updated_at > ^since_datetime,
      select: count()
    )
    |> Repo.one()
  end

  @doc """
  Compte les messages non lus dans toutes les conversations d'un utilisateur
  """
  def count_unread_conversations(user_id) do
    # Cette requête SQL optimisée est basée sur la documentation
    query = """
    WITH last_reads AS (
      SELECT 
        conversation_id, 
        last_read_at
      FROM conversation_members
      WHERE user_id = $1 AND is_active = true
    )
    SELECT 
      c.id as conversation_id,
      c.metadata -> 'name' as name,
      COUNT(m.id) as unread_count
    FROM conversations c
    JOIN last_reads lr ON c.id = lr.conversation_id
    JOIN messages m ON c.id = m.conversation_id
    WHERE 
      m.sender_id != $1
      AND (lr.last_read_at IS NULL OR m.sent_at > lr.last_read_at)
      AND NOT m.is_deleted
      AND c.is_active = TRUE
    GROUP BY c.id
    HAVING COUNT(m.id) > 0
    ORDER BY MAX(m.sent_at) DESC
    """
    
    case Ecto.Adapters.SQL.query(Repo, query, [user_id]) do
      {:ok, result} ->
        Enum.map(result.rows, fn [conversation_id, name, unread_count] ->
          %{
            conversation_id: conversation_id,
            name: name,
            unread_count: unread_count
          }
        end)
        
      {:error, _} ->
        []
    end
  end

  @doc """
  Liste les groupes de conversation d'un utilisateur
  """
  def list_user_groups(user_id) do
    from(c in Conversation,
      join: cm in ConversationMember, on: c.id == cm.conversation_id,
      where: cm.user_id == ^user_id and c.type == "group" and c.is_active == true,
      select: c
    )
    |> Repo.all()
  end
end
