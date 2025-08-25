defmodule WhisprMessaging.Conversations.ChatManagement do
  @moduledoc """
  Implémentation des fonctionnalités de gestion des conversations selon 1_chats_management.md
  
  Processus principaux :
  1. Création de conversations directes
  2. Création de conversations de groupe  
  3. Organisation des conversations (épinglage, archivage)
  4. Configuration des paramètres
  5. Synchronisation multi-appareils
  """
  
  require Logger
  
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember, ConversationSettings}
  # alias WhisprMessaging.Grpc.UserServiceClient (non utilisé actuellement)
  alias WhisprMessaging.Grpc.NotificationServiceClient
  alias WhisprMessaging.Repo

  @doc """
  Crée une conversation directe selon le processus documenté dans 1_chats_management.md
  
  Étapes :
  1. Vérifier existence utilisateur cible (gRPC UserService)
  2. Vérifier blocages mutuels (gRPC UserService)
  3. Vérifier si conversation existe déjà
  4. Créer ou réactiver la conversation
  5. Notifier l'utilisateur cible (gRPC NotificationService)
  """
  def create_direct_conversation(initiator_user_id, target_user_id, opts \\ []) do
    Logger.info("Creating direct conversation: #{initiator_user_id} -> #{target_user_id}")
    
    with {:ok, :user_exists} <- check_user_exists(target_user_id),
         {:ok, :not_blocked} <- check_user_blocked(initiator_user_id, target_user_id),
         {:ok, conversation} <- find_or_create_direct_conversation(initiator_user_id, target_user_id, opts),
         :ok <- notify_new_conversation(conversation, target_user_id) do
      
      Logger.info("Direct conversation created successfully: #{conversation.id}")
      {:ok, conversation}
    else
      {:error, :user_not_found} ->
        Logger.warning("Target user not found: #{target_user_id}")
        {:error, :user_not_found}
        
      {:error, :user_blocked} ->
        Logger.warning("User blocked: #{initiator_user_id} <-> #{target_user_id}")
        {:error, :user_blocked}
        
      {:error, reason} = error ->
        Logger.error("Failed to create direct conversation: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Crée une conversation de groupe selon le processus documenté dans 1_chats_management.md
  
  Étapes :
  1. Valider les paramètres du groupe
  2. Vérifier les permissions du créateur
  3. Valider la liste des participants
  4. Créer la conversation de groupe
  5. Ajouter les participants
  6. Configurer les paramètres par défaut
  7. Notifier tous les participants
  """
  def create_group_conversation(creator_user_id, group_attrs, participant_user_ids \\ []) do
    Logger.info("Creating group conversation by user #{creator_user_id}")
    
    with {:ok, validated_attrs} <- validate_group_attributes(group_attrs),
         {:ok, :creator_authorized} <- check_creator_permissions(creator_user_id),
         {:ok, valid_participants} <- validate_participants(participant_user_ids),
         {:ok, conversation} <- create_group_with_participants(creator_user_id, validated_attrs, valid_participants),
         :ok <- notify_group_participants(conversation, valid_participants) do
      
      Logger.info("Group conversation created successfully: #{conversation.id}")
      {:ok, conversation}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create group conversation: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Épingle une conversation selon 1_chats_management.md section 4.1
  """
  def pin_conversation(conversation_id, user_id) do
    Logger.info("Pinning conversation #{conversation_id} for user #{user_id}")
    
    case get_user_conversation_member(conversation_id, user_id) do
      {:ok, member} ->
        case update_member_settings(member, %{is_pinned: true, pinned_at: DateTime.utc_now()}) do
          {:ok, updated_member} ->
            # Synchroniser avec les autres appareils
            sync_conversation_state(conversation_id, user_id, :pinned)
            {:ok, updated_member}
            
          {:error, changeset} ->
            {:error, changeset}
        end
        
      {:error, :not_member} ->
        {:error, :not_conversation_member}
    end
  end

  @doc """
  Désépingle une conversation
  """
  def unpin_conversation(conversation_id, user_id) do
    Logger.info("Unpinning conversation #{conversation_id} for user #{user_id}")
    
    case get_user_conversation_member(conversation_id, user_id) do
      {:ok, member} ->
        case update_member_settings(member, %{is_pinned: false, pinned_at: nil}) do
          {:ok, updated_member} ->
            sync_conversation_state(conversation_id, user_id, :unpinned)
            {:ok, updated_member}
            
          {:error, changeset} ->
            {:error, changeset}
        end
        
      {:error, :not_member} ->
        {:error, :not_conversation_member}
    end
  end

  @doc """
  Archive une conversation selon 1_chats_management.md section 4.2
  """
  def archive_conversation(conversation_id, user_id) do
    Logger.info("Archiving conversation #{conversation_id} for user #{user_id}")
    
    case get_user_conversation_member(conversation_id, user_id) do
      {:ok, member} ->
        case update_member_settings(member, %{is_archived: true, archived_at: DateTime.utc_now()}) do
          {:ok, updated_member} ->
            sync_conversation_state(conversation_id, user_id, :archived)
            {:ok, updated_member}
            
          {:error, changeset} ->
            {:error, changeset}
        end
        
      {:error, :not_member} ->
        {:error, :not_conversation_member}
    end
  end

  @doc """
  Désarchive une conversation
  """
  def unarchive_conversation(conversation_id, user_id) do
    Logger.info("Unarchiving conversation #{conversation_id} for user #{user_id}")
    
    case get_user_conversation_member(conversation_id, user_id) do
      {:ok, member} ->
        case update_member_settings(member, %{is_archived: false, archived_at: nil}) do
          {:ok, updated_member} ->
            sync_conversation_state(conversation_id, user_id, :unarchived)
            {:ok, updated_member}
            
          {:error, changeset} ->
            {:error, changeset}
        end
        
      {:error, :not_member} ->
        {:error, :not_conversation_member}
    end
  end

  @doc """
  Configure les paramètres d'une conversation pour un utilisateur
  """
  def configure_conversation_settings(conversation_id, user_id, settings_attrs) do
    Logger.info("Configuring conversation #{conversation_id} settings for user #{user_id}")
    
    case get_conversation_settings(conversation_id, user_id) do
      {:ok, settings} ->
        case ConversationSettings.update_settings_changeset(settings, settings_attrs) |> Repo.update() do
          {:ok, updated_settings} ->
            sync_conversation_settings(conversation_id, user_id, updated_settings)
            {:ok, updated_settings}
            
          {:error, changeset} ->
            {:error, changeset}
        end
        
      {:error, :not_found} ->
        # Créer les paramètres s'ils n'existent pas
        create_conversation_settings(conversation_id, user_id, settings_attrs)
    end
  end

  ## Fonctions privées

  defp check_user_exists(user_id) do
    client = WhisprMessaging.Grpc.UserServiceClient
    cond do
      Code.ensure_loaded?(client) and function_exported?(client, :check_user_exists, 1) ->
        try do
          case apply(client, :check_user_exists, [user_id]) do
            {:ok, %{exists: true}} -> {:ok, :user_exists}
            {:ok, %{exists: false}} -> {:error, :user_not_found}
            {:error, reason} -> {:error, reason}
          end
        rescue
          error ->
            Logger.error("Failed to check user existence: #{inspect(error)}")
            if Mix.env() == :dev, do: {:ok, :user_exists}, else: {:error, :service_unavailable}
        end
      true ->
        if Mix.env() == :dev, do: {:ok, :user_exists}, else: {:error, :service_unavailable}
    end
  end

  defp check_user_blocked(user_id1, user_id2) do
    client = WhisprMessaging.Grpc.UserServiceClient
    cond do
      Code.ensure_loaded?(client) and function_exported?(client, :check_user_blocked, 2) ->
        try do
          case apply(client, :check_user_blocked, [user_id1, user_id2]) do
            {:ok, %{is_blocked: false}} -> {:ok, :not_blocked}
            {:ok, %{is_blocked: true}} -> {:error, :user_blocked}
            {:error, reason} -> {:error, reason}
          end
        rescue
          error ->
            Logger.error("Failed to check user blocked: #{inspect(error)}")
            if Mix.env() == :dev, do: {:ok, :not_blocked}, else: {:error, :service_unavailable}
        end
      Code.ensure_loaded?(client) and function_exported?(client, :check_user_blocks, 2) ->
        try do
          case apply(client, :check_user_blocks, [user_id1, user_id2]) do
            {:ok, %{is_blocked: false}} -> {:ok, :not_blocked}
            {:ok, %{is_blocked: true}} -> {:error, :user_blocked}
            {:error, reason} -> {:error, reason}
          end
        rescue
          error ->
            Logger.error("Failed to check user blocks: #{inspect(error)}")
            if Mix.env() == :dev, do: {:ok, :not_blocked}, else: {:error, :service_unavailable}
        end
      true ->
        if Mix.env() == :dev, do: {:ok, :not_blocked}, else: {:error, :service_unavailable}
    end
  end

  defp find_or_create_direct_conversation(user_id1, user_id2, _opts) do
    case Conversations.find_direct_conversation(user_id1, user_id2) do
      nil ->
        # Créer nouvelle conversation
        Conversations.create_direct_conversation(user_id1, user_id2)
        
      %Conversation{is_active: false} = conversation ->
        # Réactiver conversation archivée
        case Conversations.update_conversation(conversation, %{is_active: true}) do
          {:ok, updated_conversation} -> {:ok, updated_conversation}
          {:error, changeset} -> {:error, changeset}
        end
        
      %Conversation{} = conversation ->
        # Conversation existante et active
        {:ok, conversation}
    end
  end

  defp notify_new_conversation(conversation, target_user_id) do
    client = WhisprMessaging.Grpc.NotificationServiceClient
    if Code.ensure_loaded?(client) and function_exported?(client, :notify_new_conversation, 2) do
      try do
        apply(client, :notify_new_conversation, [target_user_id, conversation])
        :ok
      rescue
        error ->
          Logger.warning("Failed to send new conversation notification: #{inspect(error)}")
          :ok
      end
    else
      :ok
    end
  end

  defp validate_group_attributes(attrs) do
    # Validation basique des attributs du groupe
    required_fields = [:name]
    
    case Enum.all?(required_fields, &Map.has_key?(attrs, &1)) do
      true -> {:ok, attrs}
      false -> {:error, :missing_required_fields}
    end
  end

  defp check_creator_permissions(_creator_user_id) do
    # Placeholder - vérifier que le créateur a les permissions nécessaires
    # TODO: Implémenter selon les règles business
    {:ok, :creator_authorized}
  end

  defp validate_participants(participant_user_ids) do
    # Placeholder - valider la liste des participants
    # TODO: Vérifier existence et permissions des participants
    {:ok, participant_user_ids}
  end

  defp create_group_with_participants(creator_user_id, group_attrs, participant_user_ids) do
    # Utiliser la fonction existante pour créer le groupe
    case Conversations.create_group_conversation(nil, creator_user_id, group_attrs) do
      {:ok, conversation} ->
        # Ajouter les participants
        add_participants_to_group(conversation, participant_user_ids)
        
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp add_participants_to_group(conversation, participant_user_ids) do
    # Ajouter chaque participant à la conversation
    Enum.each(participant_user_ids, fn user_id ->
      Conversations.add_member_to_conversation(conversation, user_id)
    end)
    
    {:ok, conversation}
  end

  defp notify_group_participants(conversation, participant_user_ids) do
    try do
      Enum.each(participant_user_ids, fn user_id ->
        NotificationServiceClient.notify_new_conversation(user_id, conversation)
      end)
      :ok
    rescue
      error ->
        Logger.warning("Failed to notify group participants: #{inspect(error)}")
        :ok
    end
  end

  defp get_user_conversation_member(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :not_member}
      member -> {:ok, member}
    end
  end

  defp update_member_settings(member, attrs) do
    current = member.settings || %{}
    new_settings = Map.merge(current, Map.new(attrs))
    member
    |> ConversationMember.changeset(%{settings: new_settings})
    |> Repo.update()
  end

  defp get_conversation_settings(conversation_id, _user_id) do
    case Conversations.get_conversation_settings(conversation_id) do
      nil -> {:error, :not_found}
      settings -> {:ok, settings}
    end
  end

  defp create_conversation_settings(conversation_id, _user_id, attrs) do
    merged = Map.merge(ConversationSettings.default_settings(), attrs || %{})
    %ConversationSettings{}
    |> ConversationSettings.changeset(%{conversation_id: conversation_id, settings: merged})
    |> Repo.insert()
  end

  defp sync_conversation_state(conversation_id, user_id, action) do
    # Placeholder pour la synchronisation multi-appareils
    Logger.debug("Syncing conversation #{conversation_id} state #{action} for user #{user_id}")
    :ok
  end

  defp sync_conversation_settings(conversation_id, user_id, _settings) do
    # Placeholder pour la synchronisation des paramètres
    Logger.debug("Syncing conversation #{conversation_id} settings for user #{user_id}")
    :ok
  end

  ## Fonctions publiques pour GroupController

  @doc """
  Ajouter des membres à un groupe
  """
  def add_group_members(group_id, user_id, member_ids) do
    # Vérifier que l'utilisateur a les permissions pour modifier le groupe
    case get_user_conversation_member(group_id, user_id) do
      {:ok, member} ->
        if member.role in ["admin", "creator"] do
          # Ajouter les nouveaux membres
          results = Enum.map(member_ids, fn new_member_id ->
            Conversations.add_member_to_conversation(group_id, new_member_id)
          end)
          
          # Vérifier si tous les ajouts ont réussi
          case Enum.find(results, fn result -> match?({:error, _}, result) end) do
            nil ->
              # Tous les ajouts ont réussi
              {:ok, Conversations.get_conversation!(group_id)}
            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :unauthorized}
        end
        
      {:error, :not_member} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Retirer des membres d'un groupe
  """
  def remove_group_members(group_id, user_id, member_ids) do
    # Vérifier que l'utilisateur a les permissions pour modifier le groupe
    case get_user_conversation_member(group_id, user_id) do
      {:ok, member} ->
        if member.role in ["admin", "creator"] do
          # Retirer les membres
          results = Enum.map(member_ids, fn member_id_to_remove ->
            Conversations.remove_member_from_conversation(group_id, member_id_to_remove)
          end)
          
          # Vérifier si tous les retraits ont réussi
          case Enum.find(results, fn result -> match?({:error, _}, result) end) do
            nil ->
              # Tous les retraits ont réussi
              {:ok, Conversations.get_conversation!(group_id)}
            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :unauthorized}
        end
        
      {:error, :not_member} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Mettre à jour les paramètres d'un groupe
  """
  def update_group_settings(group_id, user_id, group_params) do
    # Vérifier que l'utilisateur a les permissions pour modifier le groupe
    case get_user_conversation_member(group_id, user_id) do
      {:ok, member} ->
        if member.role in ["admin", "creator"] do
          # Mettre à jour les paramètres de la conversation
          case Conversations.update_conversation_settings(group_id, group_params) do
            {:ok, conversation} ->
              {:ok, conversation}
            {:error, changeset} ->
              {:error, changeset}
          end
        else
          {:error, :unauthorized}
        end
        
      {:error, :not_member} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Quitter un groupe
  """
  def leave_group(group_id, user_id) do
    # Vérifier que l'utilisateur est membre du groupe
    case get_user_conversation_member(group_id, user_id) do
      {:ok, member} ->
        # Vérifier que ce n'est pas le créateur (qui ne peut pas quitter)
        if member.role == "creator" do
          {:error, :unauthorized}
        else
          # Retirer l'utilisateur du groupe
          Conversations.remove_member_from_conversation(group_id, user_id)
        end
        
      {:error, :not_member} ->
        {:error, :not_found}
    end
  end
end
