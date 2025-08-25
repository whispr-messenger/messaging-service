defmodule WhisprMessaging.WorkersMessageCleanup do
  @moduledoc """
  Worker de nettoyage des messages selon system_design.md
  Applique les politiques de rétention et nettoie les messages expirés.
  """
  use GenServer
  
  require Logger
  
  alias WhisprMessaging.Messages
  alias WhisprMessaging.Conversations

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Programmer le premier nettoyage
    schedule_cleanup()
    
    state = %{
      last_cleanup: DateTime.utc_now(),
      messages_cleaned: 0
    }
    
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup_messages, state) do
    cleaned_count = perform_message_cleanup()
    
    schedule_cleanup()
    
    new_state = %{state | 
      last_cleanup: DateTime.utc_now(),
      messages_cleaned: state.messages_cleaned + cleaned_count
    }
    
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_cleanup_stats, _from, state) do
    stats = %{
      last_cleanup: state.last_cleanup,
      total_cleaned: state.messages_cleaned
    }
    
    {:reply, stats, state}
  end

  ## Private Functions

  defp perform_message_cleanup do
    try do
      # Appliquer les politiques de rétention selon la conversation
      retention_policies = get_retention_policies()
      
      total_cleaned = Enum.reduce(retention_policies, 0, fn policy, acc ->
        cleaned = apply_retention_policy(policy)
        acc + cleaned
      end)
      
      Logger.info("Message cleanup completed: #{total_cleaned} messages processed")
      total_cleaned
    rescue
      error ->
        Logger.warning("Message cleanup failed: #{inspect(error)}")
        0
    end
  end

  defp get_retention_policies do
    # Récupérer les politiques de rétention par conversation
    Conversations.list_conversations_with_retention_policies()
  end

  defp apply_retention_policy(%{conversation_id: conv_id, retention_days: days}) when is_integer(days) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days, :day)
    
    # Marquer les messages comme supprimés selon la politique
    Messages.mark_messages_as_expired(conv_id, cutoff_date)
  end

  defp apply_retention_policy(_policy), do: 0

  defp schedule_cleanup do
    # Nettoyage quotidien à 2h du matin
    next_cleanup = calculate_next_cleanup_time()
    delay_ms = DateTime.diff(next_cleanup, DateTime.utc_now(), :millisecond)
    
    if delay_ms > 0 do
      Process.send_after(self(), :cleanup_messages, delay_ms)
    else
      # Si c'est déjà passé, programmer pour demain
      tomorrow = DateTime.add(next_cleanup, 1, :day)
      delay_ms = DateTime.diff(tomorrow, DateTime.utc_now(), :millisecond)
      Process.send_after(self(), :cleanup_messages, delay_ms)
    end
  end

  defp calculate_next_cleanup_time do
    now = DateTime.utc_now()
    
    # 2h du matin UTC
    %{now | hour: 2, minute: 0, second: 0, microsecond: {0, 0}}
  end
end
