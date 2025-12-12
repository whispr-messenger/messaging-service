defmodule WhisprMessaging.Repo do
  use Ecto.Repo,
    otp_app: :whispr_messaging,
    adapter: Ecto.Adapters.Postgres

  require Logger

  @doc """
  Dynamically loads the repository url from the
  DATABASE_URL environment variable.
  """
  def init(_, opts) do
    {:ok, Keyword.put(opts, :url, System.get_env("DATABASE_URL"))}
  end

  @doc """
  Health check for the database connection.
  """
  def health_check do
    query!("SELECT 1", [], timeout: 5_000)
    :ok
  rescue
    exception ->
      Logger.error("Database health check failed: #{inspect(exception)}")
      {:error, exception}
  end

  @doc """
  Get connection information for monitoring.
  """
  def connection_info do
    query!(
      """
        SELECT
          current_database() as database,
          current_user as user,
          version() as version,
          now() as current_time
      """,
      [],
      timeout: 5_000
    )
  rescue
    exception ->
      Logger.error("Failed to get connection info: #{inspect(exception)}")
      {:error, exception}
  end

  @doc """
  Execute a function in a transaction with proper error handling.
  """
  def safe_transact(fun) when is_function(fun, 0) do
    transaction(fn ->
      try do
        fun.()
      rescue
        exception ->
          Logger.error("Transaction failed: #{inspect(exception)}")
          rollback(exception)
      end
    end)
  end

  @doc """
  Safely execute a query with timeout and error handling.
  """
  def safe_query(query, params \\ [], opts \\ []) do
    default_opts = [timeout: 15_000, log: :info]
    merged_opts = Keyword.merge(default_opts, opts)

    try do
      {:ok, query!(query, params, merged_opts)}
    rescue
      exception ->
        Logger.error("Query failed: #{inspect(exception)}", query: query, params: params)
        {:error, exception}
    end
  end
end
