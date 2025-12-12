defmodule WhisprMessaging.ConversationSupervisor do
  @moduledoc """
  DynamicSupervisor for managing ConversationServer processes.

  Handles starting, stopping, and monitoring individual conversation GenServers.
  Provides fault tolerance with automatic restarts and cleanup.
  """

  use DynamicSupervisor
  require Logger

  alias WhisprMessaging.ConversationServer

  @doc """
  Starts the conversation supervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a conversation server for the given conversation ID.
  """
  def start_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        child_spec = {ConversationServer, conversation_id}

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} ->
            Logger.info(
              "Started ConversationServer for conversation #{conversation_id}, PID: #{inspect(pid)}"
            )

            {:ok, pid}

          {:error, {:already_started, pid}} ->
            Logger.debug(
              "ConversationServer for conversation #{conversation_id} already exists, PID: #{inspect(pid)}"
            )

            {:ok, pid}

          {:error, reason} ->
            Logger.error(
              "Failed to start ConversationServer for conversation #{conversation_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      pid ->
        Logger.debug(
          "ConversationServer for conversation #{conversation_id} already running, PID: #{inspect(pid)}"
        )

        {:ok, pid}
    end
  end

  @doc """
  Stops a conversation server for the given conversation ID.
  """
  def stop_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        Logger.debug("No ConversationServer found for conversation #{conversation_id}")
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("Stopped ConversationServer for conversation #{conversation_id}")
            :ok

          {:error, reason} ->
            Logger.error(
              "Failed to stop ConversationServer for conversation #{conversation_id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Gets the PID of a conversation server if it exists.
  """
  def get_conversation_pid(conversation_id) do
    case Registry.lookup(WhisprMessaging.ConversationRegistry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Lists all active conversation servers.
  """
  def list_conversations do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&Process.alive?/1)
    |> Enum.map(&get_conversation_id_from_pid/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets conversation server statistics.
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
  Ensures a conversation server is running for the given conversation ID.
  """
  def ensure_conversation_server(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil -> start_conversation(conversation_id)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Stops all conversation servers (for graceful shutdown).
  """
  def stop_all_conversations do
    children = DynamicSupervisor.which_children(__MODULE__)

    Enum.each(children, fn {_, pid, _, _} ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(__MODULE__, pid)
      end
    end)

    Logger.info("Stopped all conversation servers")
  end

  @doc """
  Performs health check on conversation servers.
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

  # DynamicSupervisor Callbacks

  @impl true
  def init(_init_arg) do
    Logger.info("Starting ConversationSupervisor")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # Private Functions

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

  # Management functions for operations

  @doc """
  Restarts a conversation server if it's unhealthy.
  """
  def restart_conversation(conversation_id) do
    case get_conversation_pid(conversation_id) do
      nil ->
        start_conversation(conversation_id)

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            start_conversation(conversation_id)

          error ->
            error
        end
    end
  end

  @doc """
  Gracefully shuts down idle conversation servers.
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
      Logger.info("Stopping idle conversation server: #{conversation_id}")
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

      pid ->
        try do
          state = ConversationServer.get_state(conversation_id)
          minutes_since_activity = DateTime.diff(DateTime.utc_now(), state.last_activity, :minute)
          minutes_since_activity >= threshold_minutes
        catch
          # Consider unresponsive processes as idle
          :exit, _ -> true
        end
    end
  end
end
