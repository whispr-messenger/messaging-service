defmodule WhisprMessagingWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build and query models.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  during tests are automatically rolled back.
  """

  use ExUnit.CaseTemplate

  import Plug.Conn

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import WhisprMessagingWeb.ConnCase

      alias WhisprMessagingWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint WhisprMessagingWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(WhisprMessaging.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup a test connection with authentication headers.
  """
  def authenticated_conn(conn, user_id) do
    conn
    |> put_req_header("authorization", "Bearer test_token_#{user_id}")
    |> put_req_header("content-type", "application/json")
  end

  @doc """
  Setup a test connection with authorization and JSON headers.
  """
  def json_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end

  @doc """
  Decodes JSON response body.
  """
  def json_response(conn) do
    conn.resp_body
    |> Jason.decode!()
  end
end
