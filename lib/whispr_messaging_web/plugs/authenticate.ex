defmodule WhisprMessagingWeb.Plugs.Authenticate do
  @moduledoc """
  Plug to authenticate users and assign user_id to the connection.
  Supports both X-User-Id (trusted gateway header) and Authorization: Bearer <token>.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_user_id(conn) do
      {:ok, user_id} ->
        assign(conn, :user_id, user_id)

      {:error, :unauthorized} ->
        # For certain routes, we might want to fail open or handle elsewhere,
        # but for now we enforce identity if any auth header is present
        # or just proceed to let controllers handle missing assignments.
        conn
    end
  end

  defp get_user_id(conn) do
    # 1. Check for trusted gateway header
    case get_req_header(conn, "x-user-id") do
      [user_id | _] when user_id != "" ->
        {:ok, user_id}

      _ ->
        # 2. Check for Bearer token
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] ->
            verify_token(token)

          _ ->
            {:error, :unauthorized}
        end
    end
  end

  defp verify_token(token) do
    # Local development/test convenience for legacy tokens if needed
    if String.starts_with?(token, "test_token_") do
      user_id = String.replace(token, "test_token_", "")
      {:ok, user_id}
    else
      case Phoenix.Token.verify(
             WhisprMessagingWeb.Endpoint,
             "user auth",
             token,
             max_age: 86_400
           ) do
        {:ok, user_id} -> {:ok, user_id}
        {:error, _reason} -> {:error, :unauthorized}
      end
    end
  end
end
