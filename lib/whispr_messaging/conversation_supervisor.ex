defmodule WhisprMessaging.ConversationSupervisor do
  @moduledoc """
  DynamicSupervisor qui gere les processus ConversationServer.

  Demarre, stoppe et surveille les GenServers de conversation. Tolere
  les fautes via redemarrage automatique et nettoyage des PID morts.
  """

  use DynamicSupervisor
  require Logger

  alias WhisprMessaging.ConversationServer

  @doc """
  Demarre le superviseur de conversations.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Demarre un ConversationServer pour l'ID de conversation donne.
  """
  def start_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        child_spec = {ConversationServer, conversation_id}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} ->
            Logger.info("ConversationServer started",
              conversation_id: conversation_id,
              pid: inspect(pid)
            )

            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.debug("ConversationServer already exists",
              conversation_id: conversation_id,
              pid: inspect(pid)
            )

            {:ok, pid}

          {:error, reason} ->
            Logger.error("ConversationServer start failed",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end

      pid ->
        Logger.debug("ConversationServer already running",
          conversation_id: conversation_id,
          pid: inspect(pid)
        )

        {:ok, pid}
    end
  end

  @doc """
  Stoppe le ConversationServer associe a la conversation donnee.
  """
  def stop_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        Logger.debug("No ConversationServer found", conversation_id: conversation_id)
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("ConversationServer stopped", conversation_id: conversation_id)
            :ok

          {:error, reason} ->
            Logger.error("ConversationServer stop failed",
              conversation_id: conversation_id,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Renvoie le PID du ConversationServer s'il tourne, sinon nil.
  """
  def get_conversation_pid(conversation_id) do
    case Registry.lookup(WhisprMessaging.ConversationRegistry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Liste toutes les conversations actuellement actives.
  """
  def list_conversations do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&Process.alive?/1)
    |> Enum.map(&get_conversation_id_from_pid/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Statistiques sur les ConversationServers (total, actifs, memoire).
  """
  def get_stats do
    children = DynamicSupervisor.which_children(__MODULE__)

    %{
      total_conversations: length(children),
      active_conversations: Enum.count(children, fn {_, pid, _, _} -> Process.alive?(pid) end),
      memory_usage: get_total_memory_usage(children)
    }
  end

  @doc """
  Garantit qu'un ConversationServer tourne pour la conversation donnee
  (le demarre si besoin).
  """
  def ensure_conversation_server(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil -> start_conversation(conversation_id)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Stoppe tous les ConversationServers (utilise pour un arret propre).
  """
  def stop_all_conversations do
    children = DynamicSupervisor.which_children(__MODULE__)

    Enum.each(children, fn {_, pid, _, _} ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(__MODULE__, pid)
      end
    end)

    Logger.info("All conversation servers stopped")
  end

  @doc """
  Healthcheck sur les ConversationServers.
  """
  def health_check do
    children = DynamicSupervisor.which_children(__MODULE__)
    total = length(children)
    healthy = Enum.count(children, fn {_, pid, _, _} -> Process.alive?(pid) end)

    status = if healthy == total, do: :healthy, else: :degraded

    %{
      status: status,
      total_processes: total,
      healthy_processes: healthy,
      unhealthy_processes: total - healthy
    }
  end

  # Callbacks DynamicSupervisor

  @impl true
  def init(_init_arg) do
    Logger.metadata(domain: :conversation_supervisor)
    Logger.info("ConversationSupervisor starting")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Fonctions privees

  defp get_conversation_id_from_pid(pid) do
    case Registry.keys(WhisprMessaging.ConversationRegistry, pid) do
      [conversation_id] -> conversation_id
      _ -> nil
    end
  end

  defp get_total_memory_usage(children) do
    children
    |> Enum.map(fn {_, pid, _, _} -> get_process_memory(pid) end)
    |> Enum.sum()
  end

  defp get_process_memory(pid) do
    if Process.alive?(pid) do
      case Process.info(pid, :memory) do
        {:memory, memory} -> memory
        _ -> 0
      end
    else
      0
    end
  end

  # Fonctions de gestion utilisees en operationnel

  @doc """
  Redemarre un ConversationServer si son etat est instable.
  """
  def restart_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        start_conversation(conversation_id)

      pid ->
        ref = Process.monitor(pid)

        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            # Attend que le Registry soit nettoye (monitor fire apres l'exit
            # final) avant de demarrer le nouveau, sinon get_conversation_pid
            # peut retourner l'ancien pid mourant.
            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              1_000 -> :timeout
            end

            start_conversation(conversation_id)

          error ->
            Process.demonitor(ref, [:flush])
            error
        end
    end
  end

  @doc """
  Stoppe proprement les ConversationServers inactifs depuis trop longtemps.
  """
  def cleanup_idle_conversations(idle_threshold_minutes \\ 30) do
    children = DynamicSupervisor.which_children(__MODULE__)

    idle_conversations =
      children
      |> Enum.map(fn {_, pid, _, _} -> pid end)
      |> Enum.filter(&Process.alive?/1)
      |> Enum.map(&get_conversation_id_from_pid/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&conversation_idle?(&1, idle_threshold_minutes))

    Enum.each(idle_conversations, fn conversation_id ->
      Logger.info("Stopping idle conversation server", conversation_id: conversation_id)
      stop_conversation(conversation_id)
    end)

    %{
      total_checked: length(children),
      idle_stopped: length(idle_conversations),
      idle_conversation_ids: idle_conversations
    }
  end

  defp conversation_idle?(conversation_id, threshold_minutes) do
    case get_conversation_pid(conversation_id) do
      nil ->
        false

      _pid ->
        try do
          state = ConversationServer.get_state(conversation_id)
          minutes_since_activity = DateTime.diff(DateTime.utc_now(), state.last_activity, :minute)
          minutes_since_activity >= threshold_minutes
        catch
          # un process qui ne repond plus est traite comme inactif
          :exit, _ -> true
        end
    end
  end
end
