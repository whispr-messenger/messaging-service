defmodule WhisprMessaging.Conversations.Registry do
  @moduledoc """
  Registry pour la localisation des processus de conversation selon system_design.md
  Permet de retrouver rapidement le processus responsable d'une conversation donnée.
  """
  
  @doc """
  Démarre le registry pour les processus de conversation
  """
  def start_link do
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @doc """
  Enregistre un processus de conversation
  """
  def register_conversation(conversation_id) do
    Registry.register(__MODULE__, conversation_id, nil)
  end

  @doc """
  Trouve le processus d'une conversation
  """
  def lookup_conversation(conversation_id) do
    case Registry.lookup(__MODULE__, conversation_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Désenregistre un processus de conversation
  """
  def unregister_conversation(conversation_id) do
    Registry.unregister(__MODULE__, conversation_id)
  end

  @doc """
  Liste toutes les conversations enregistrées
  """
  def list_conversations do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
  end

  @doc """
  Compte le nombre de conversations actives
  """
  def count_active_conversations do
    Registry.count(__MODULE__)
  end
end
