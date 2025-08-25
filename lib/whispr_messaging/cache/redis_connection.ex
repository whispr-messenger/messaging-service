defmodule WhisprMessaging.Cache.RedisConnection do
  @moduledoc """
  Gestionnaire des connexions Redis avec pools multiples
  selon les spécifications de cache distribué
  """
  
  use Supervisor
  
  require Logger

  @pools [:main_pool, :session_pool, :queue_pool]

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    redis_enabled = Application.get_env(:whispr_messaging, :redis_enabled, true)
    
    if redis_enabled do
      Logger.info("Starting Redis connection pools")
      
      redis_config = Application.get_env(:whispr_messaging, :redis)
      
      children = 
        @pools
        |> Enum.map(&create_pool_child_spec(&1, redis_config))
        |> Enum.filter(& &1) # Filtrer les pools non configurés
      
      if Enum.empty?(children) do
        Logger.warning("No Redis pools configured")
      else
        Logger.info("Starting #{length(children)} Redis pools: #{inspect(@pools)}")
      end

      opts = [strategy: :one_for_one, name: WhisprMessaging.Cache.RedisSupervisor]
      Supervisor.init(children, opts)
    else
      Logger.info("Redis disabled - running in memory-only mode")
      opts = [strategy: :one_for_one, name: WhisprMessaging.Cache.RedisSupervisor]
      Supervisor.init([], opts)
    end
  end

  defp create_pool_child_spec(pool_name, redis_config) do
    case Keyword.get(redis_config, pool_name) do
      nil ->
        Logger.warning("Redis pool #{pool_name} not configured")
        nil
        
      pool_config ->
        # Configuration avec ID unique pour chaque pool
        redix_config = Keyword.merge(pool_config, [name: :"RedisPool_#{pool_name}"])
        
        %{
          id: :"RedisConnection_#{pool_name}",
          start: {Redix, :start_link, [redix_config]},
          type: :worker,
          restart: :permanent,
          shutdown: 5000
        }
    end
  end

  ## Fonctions d'interface pour les pools

  @doc """
  Exécuter une commande Redis sur le pool principal
  """
  def command(command, args \\ []) do
    execute_command(:main_pool, command, args)
  end

  @doc """
  Exécuter une commande Redis sur le pool de sessions
  """
  def session_command(command, args \\ []) do
    execute_command(:session_pool, command, args)
  end

  @doc """
  Exécuter une commande Redis sur le pool de queues
  """
  def queue_command(command, args \\ []) do
    execute_command(:queue_pool, command, args)
  end

  @doc """
  Pipeline de commandes sur le pool principal
  """
  def pipeline(commands) when is_list(commands) do
    execute_pipeline(:main_pool, commands)
  end

  @doc """
  Pipeline de commandes sur un pool spécifique
  """
  def pipeline(pool, commands) when is_atom(pool) and is_list(commands) do
    execute_pipeline(pool, commands)
  end

  @doc """
  Exécuter une commande Redis sur un pool spécifique (fonction publique pour workers)
  """
  def execute_command(pool_name, command, args) do
    # Convertir le nom du pool vers le nom du processus
    process_name = :"RedisPool_#{pool_name}"
    
    # Si le pool n'est pas démarré, éviter l'appel Redix
    if Process.whereis(process_name) == nil do
      Logger.debug("Redis pool not available", %{pool: pool_name, command: command})
      return_unavailable(pool_name)
    else
    try do
      case Redix.command(process_name, [command | args]) do
        {:ok, result} ->
          {:ok, result}
          
        {:error, %Redix.Error{message: message}} ->
          Logger.error("Redis command failed", %{
            pool: pool_name,
            command: command,
            error: message
          })
          {:error, {:redis_error, message}}
          
        {:error, reason} ->
          Logger.error("Redis connection failed", %{
            pool: pool_name,
            command: command,
            error: reason
          })
          {:error, {:connection_error, reason}}
      end
    catch
      :exit, reason ->
        Logger.error("Redis command crashed", %{
          pool: pool_name,
          command: command,
          reason: reason
        })
        {:error, {:redis_crash, reason}}
    end
    end
  end

  ## Fonctions privées

  defp execute_pipeline(pool_name, commands) do
    # Convertir le nom du pool vers le nom du processus
    process_name = :"RedisPool_#{pool_name}"
    
    if Process.whereis(process_name) == nil do
      Logger.debug("Redis pool not available for pipeline", %{pool: pool_name, count: length(commands)})
      return_unavailable(pool_name)
    else
    try do
      case Redix.pipeline(process_name, commands) do
        {:ok, results} ->
          {:ok, results}
          
        {:error, %Redix.Error{message: message}} ->
          Logger.error("Redis pipeline failed", %{
            pool: pool_name,
            commands_count: length(commands),
            error: message
          })
          {:error, {:redis_error, message}}
          
        {:error, reason} ->
          Logger.error("Redis pipeline connection failed", %{
            pool: pool_name,
            commands_count: length(commands),
            error: reason
          })
          {:error, {:connection_error, reason}}
      end
    catch
      :exit, reason ->
        Logger.error("Redis pipeline crashed", %{
          pool: pool_name,
          commands_count: length(commands),
          reason: reason
        })
        {:error, {:redis_crash, reason}}
    end
    end
  end

  ## Fonctions utilitaires

  @doc """
  Vérifier la santé des connexions Redis
  """
  def health_check do
    @pools
    |> Enum.map(fn pool ->
      process_name = :"RedisPool_#{pool}"
      case Process.whereis(process_name) do
        nil -> {pool, :disabled}
        _ ->
          case execute_command(pool, "PING", []) do
            {:ok, "PONG"} -> {pool, :healthy}
            {:error, reason} -> {pool, {:error, reason}}
          end
      end
    end)
    |> Enum.into(%{})
  end

  @doc """
  Statistiques des pools Redis
  """
  def pool_stats do
    @pools
    |> Enum.map(fn pool ->
      process_name = :"RedisPool_#{pool}"
      
      if Process.whereis(process_name) == nil do
        {pool, %{status: :disabled}}
      else
      try do
        # Utiliser PING pour tester la connexion
        case Redix.command(process_name, ["PING"]) do
          {:ok, "PONG"} ->
            {pool, %{status: :connected, process: process_name}}
          {:error, reason} ->
            {pool, %{status: :error, error: inspect(reason)}}
        end
      rescue
        error -> {pool, %{status: :error, error: inspect(error)}}
      end
      end
    end)
    |> Enum.into(%{})
  end

  defp return_unavailable(_pool_name), do: {:error, :pool_unavailable}
end
