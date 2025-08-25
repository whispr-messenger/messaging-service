defmodule WhisprMessaging.Conversations.ConversationProcess do
  @moduledoc """
  Processus GenServer dédié à une conversation selon system_design.md
  
  Chaque conversation est gérée par un processus GenServer dédié qui :
  - Maintient l'état courant de la conversation
  - Gère les abonnements des utilisateurs connectés
  - Coordonne la distribution des messages
  - Optimise les performances avec un état en mémoire
  """
  use GenServer
  
  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Conversations.Registry, as: ConversationRegistry
  
  defstruct [
    :conversation_id,
    :conversation,
    :connected_users,
    :typing_users,
    :last_activity,
    :message_cache
  ]

  ## Client API

  def start_link(conversation_id) do
    GenServer.start_link(__MODULE__, conversation_id, name: via_tuple(conversation_id))
  end

  @doc """
  Envoie un message dans la conversation
  """
  def send_message(conversation_id, message_attrs) do
    GenServer.call(via_tuple(conversation_id), {:send_message, message_attrs})
  end

  @doc """
  Ajoute un utilisateur connecté à la conversation
  """
  def add_connected_user(conversation_id, user_id, channel_pid) do
    GenServer.call(via_tuple(conversation_id), {:add_connected_user, user_id, channel_pid})
  end

  @doc """
  Retire un utilisateur connecté de la conversation
  """
  def remove_connected_user(conversation_id, user_id) do
    GenServer.call(via_tuple(conversation_id), {:remove_connected_user, user_id})
  end

  @doc """
  Marque un utilisateur comme en train de taper
  """
  def user_typing(conversation_id, user_id) do
    GenServer.cast(via_tuple(conversation_id), {:user_typing, user_id})
  end

  @doc """
  Marque un utilisateur comme ayant arrêté de taper
  """
  def user_stopped_typing(conversation_id, user_id) do
    GenServer.cast(via_tuple(conversation_id), {:user_stopped_typing, user_id})
  end

  @doc """
  Récupère l'état actuel de la conversation
  """
  def get_state(conversation_id) do
    GenServer.call(via_tuple(conversation_id), :get_state)
  end

  ## Server Implementation

  @impl true
  def init(conversation_id) do
    # Enregistrer dans le registry
    ConversationRegistry.register_conversation(conversation_id)
    
    # Charger la conversation depuis la base
    conversation = Conversations.get_conversation!(conversation_id)
    
    # Initialiser l'état
    state = %__MODULE__{
      conversation_id: conversation_id,
      conversation: conversation,
      connected_users: %{},
      typing_users: MapSet.new(),
      last_activity: DateTime.utc_now(),
      message_cache: []
    }
    
    # Programmer le nettoyage périodique
    schedule_cleanup()
    
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message_attrs}, _from, state) do
    case Messages.create_message(message_attrs) do
      {:ok, message} ->
        # Mettre à jour le cache local
        updated_cache = [message | state.message_cache] |> Enum.take(50)
        
        # Diffuser le message aux utilisateurs connectés
        broadcast_to_connected_users(state, {:new_message, message})
        
        # Mettre à jour l'état
        new_state = %{state | 
          message_cache: updated_cache,
          last_activity: DateTime.utc_now()
        }
        
        {:reply, {:ok, message}, new_state}
        
      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:add_connected_user, user_id, channel_pid}, _from, state) do
    # Ajouter l'utilisateur aux connectés
    new_connected_users = Map.put(state.connected_users, user_id, channel_pid)
    
    # Monitorer le processus channel pour détecter les déconnexions
    Process.monitor(channel_pid)
    
    new_state = %{state | connected_users: new_connected_users}
    
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_connected_user, user_id}, _from, state) do
    new_connected_users = Map.delete(state.connected_users, user_id)
    new_typing_users = MapSet.delete(state.typing_users, user_id)
    
    new_state = %{state | 
      connected_users: new_connected_users,
      typing_users: new_typing_users
    }
    
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    public_state = %{
      conversation_id: state.conversation_id,
      connected_users: Map.keys(state.connected_users),
      typing_users: MapSet.to_list(state.typing_users),
      last_activity: state.last_activity,
      cached_messages_count: length(state.message_cache)
    }
    
    {:reply, public_state, state}
  end

  @impl true
  def handle_call(:get_conversation_id, _from, state) do
    {:reply, state.conversation_id, state}
  end

  @impl true
  def handle_cast({:user_typing, user_id}, state) do
    new_typing_users = MapSet.put(state.typing_users, user_id)
    
    # Diffuser l'indicateur de frappe
    broadcast_to_connected_users(state, {:user_typing, user_id}, exclude: [user_id])
    
    # Programmer l'arrêt automatique après 5 secondes
    Process.send_after(self(), {:stop_typing, user_id}, 5_000)
    
    {:noreply, %{state | typing_users: new_typing_users}}
  end

  @impl true
  def handle_cast({:user_stopped_typing, user_id}, state) do
    new_typing_users = MapSet.delete(state.typing_users, user_id)
    
    # Diffuser l'arrêt de frappe
    broadcast_to_connected_users(state, {:user_stopped_typing, user_id}, exclude: [user_id])
    
    {:noreply, %{state | typing_users: new_typing_users}}
  end

  @impl true
  def handle_info({:stop_typing, user_id}, state) do
    # Arrêt automatique de la frappe après timeout
    if MapSet.member?(state.typing_users, user_id) do
      new_typing_users = MapSet.delete(state.typing_users, user_id)
      broadcast_to_connected_users(state, {:user_stopped_typing, user_id}, exclude: [user_id])
      {:noreply, %{state | typing_users: new_typing_users}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Un channel s'est déconnecté, retirer l'utilisateur
    case Enum.find(state.connected_users, fn {_user_id, channel_pid} -> channel_pid == pid end) do
      {user_id, _pid} ->
        new_connected_users = Map.delete(state.connected_users, user_id)
        new_typing_users = MapSet.delete(state.typing_users, user_id)
        
        new_state = %{state | 
          connected_users: new_connected_users,
          typing_users: new_typing_users
        }
        
        {:noreply, new_state}
        
      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Nettoyage périodique du cache si la conversation est inactive
    time_since_activity = DateTime.diff(DateTime.utc_now(), state.last_activity, :minute)
    
    if time_since_activity > 30 and map_size(state.connected_users) == 0 do
      # Conversation inactive depuis 30 min et personne connecté -> arrêt du processus
      {:stop, :normal, state}
    else
      # Programmer le prochain nettoyage
      schedule_cleanup()
      {:noreply, state}
    end
  end

  ## Private Functions

  defp via_tuple(conversation_id) do
    {:via, Registry, {ConversationRegistry, conversation_id}}
  end

  defp broadcast_to_connected_users(state, message, opts \\ []) do
    exclude_users = Keyword.get(opts, :exclude, [])
    
    state.connected_users
    |> Enum.reject(fn {user_id, _} -> user_id in exclude_users end)
    |> Enum.each(fn {_user_id, channel_pid} ->
      send(channel_pid, message)
    end)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end
end
