defmodule WhisprMessaging.Conversations.Supervisor do
  @moduledoc """
  Superviseur dynamique pour les processus de conversation selon system_design.md
  Chaque conversation est gérée par un processus GenServer distinct permettant 
  l'isolation et le scaling de chaque conversation individuellement.
  """
  use DynamicSupervisor
  
  alias WhisprMessaging.Conversations.ConversationProcess
  
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Démarre un processus pour une conversation spécifique
  """
  def start_conversation(conversation_id) do
    child_spec = %{
      id: ConversationProcess,
      start: {ConversationProcess, :start_link, [conversation_id]},
      restart: :temporary
    }
    
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Arrête le processus d'une conversation
  """
  def stop_conversation(conversation_id) do
    case Registry.lookup(WhisprMessaging.Conversations.Registry, conversation_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc """
  Liste toutes les conversations actives
  """
  def list_active_conversations do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> 
      GenServer.call(pid, :get_conversation_id)
    end)
  end

  @doc """
  Récupère le PID du processus d'une conversation
  """
  def get_conversation_process(conversation_id) do
    case Registry.lookup(WhisprMessaging.Conversations.Registry, conversation_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
