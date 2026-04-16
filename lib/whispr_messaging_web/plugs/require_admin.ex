defmodule WhisprMessagingWeb.Plugs.RequireAdmin do
  @moduledoc """
  Plug that gates admin-only endpoints by checking the user's role.

  ## How it works

  1. Extracts `user_id` from `conn.assigns` (set by the Authenticate plug).
  2. Checks Redis cache (`admin_role:<user_id>`) for a previously resolved role.
  3. On cache miss, calls the user-service `GET /user/v1/roles/me` endpoint,
     forwarding the original Authorization header so the user-service can
     authenticate the request.
  4. Caches the result in Redis for 5 minutes.
  5. If the role is `"admin"` or `"moderator"`, the request passes through.
  6. Otherwise, returns 403 Forbidden and halts.

  ## Fallback

  If the user-service is unreachable and the cache is empty, the plug checks
  the `ADMIN_USER_IDS` environment variable (comma-separated list of user UUIDs)
  as a last resort.

  ## Configuration

  - `USER_SERVICE_HTTP_URL` — base URL of the user-service HTTP API
    (default: `http://user-service:3002`)
  - `ADMIN_USER_IDS` — comma-separated fallback admin user IDs
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  # In the test environment, accept any authenticated user as admin.
  # This mirrors the bypass in Authenticate for test tokens.
  if Mix.env() == :test do
    def call(conn, _opts) do
      if conn.assigns[:user_id] do
        assign(conn, :user_role, "admin")
      else
        forbidden(conn)
      end
    end
  else
    alias WhisprMessaging.Cache

    @cache_ttl 300
    @request_timeout 5_000

    def call(conn, _opts) do
      user_id = conn.assigns[:user_id]

      cond do
        is_nil(user_id) ->
          forbidden(conn)

        user_id in fallback_admin_ids() ->
          # Static admin overlay — bypasses any role the user-service might report.
          # Used to grant ad-hoc admin rights without writing to the user-service DB.
          assign(conn, :user_role, "admin")

        true ->
          case resolve_role(conn, user_id) do
            {:ok, role} when role in ["admin", "moderator"] ->
              assign(conn, :user_role, role)

            _ ->
              forbidden(conn)
          end
      end
    end

    # -------------------------------------------------------------------------
    # Role resolution (cache -> user-service -> env fallback)
    # -------------------------------------------------------------------------

    defp resolve_role(conn, user_id) do
      cache_key = "admin_role:#{user_id}"

      case Cache.get(cache_key) do
        {:ok, %{"role" => role}} ->
          {:ok, role}

        {:ok, role} when is_binary(role) ->
          {:ok, role}

        _ ->
          fetch_and_cache_role(conn, user_id, cache_key)
      end
    end

    defp fetch_and_cache_role(conn, user_id, cache_key) do
      case call_user_service(conn) do
        {:ok, role} ->
          Cache.set(cache_key, %{"role" => role}, @cache_ttl)
          {:ok, role}

        :error ->
          fallback_check(user_id)
      end
    end

    defp call_user_service(conn) do
      url = user_service_url() <> "/user/v1/roles/me"

      headers =
        conn
        |> get_req_header("authorization")
        |> case do
          [auth | _] -> [{"authorization", auth}, {"accept", "application/json"}]
          _ -> [{"accept", "application/json"}]
        end

      request = Finch.build(:get, url, headers)

      case Finch.request(request, WhisprMessaging.Finch, receive_timeout: @request_timeout) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"role" => role}} when is_binary(role) ->
              {:ok, role}

            _ ->
              Logger.warning("[RequireAdmin] Unexpected response body from user-service: #{body}")

              :error
          end

        {:ok, %Finch.Response{status: status}} ->
          Logger.warning("[RequireAdmin] user-service returned status #{status}")
          :error

        {:error, reason} ->
          Logger.error("[RequireAdmin] user-service unreachable: #{inspect(reason)}")
          :error
      end
    end

    defp fallback_check(user_id) do
      admin_ids = fallback_admin_ids()

      if user_id in admin_ids do
        Logger.info(
          "[RequireAdmin] Granted access via ADMIN_USER_IDS fallback for user #{user_id}"
        )

        {:ok, "admin"}
      else
        :error
      end
    end

    # -------------------------------------------------------------------------
    # Configuration helpers
    # -------------------------------------------------------------------------

    defp user_service_url do
      System.get_env("USER_SERVICE_HTTP_URL") || "http://user-service:3002"
    end

    defp fallback_admin_ids do
      case System.get_env("ADMIN_USER_IDS") do
        nil ->
          []

        ids ->
          ids
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Response helpers (shared across all environments)
  # ---------------------------------------------------------------------------

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "Admin or moderator role required"}))
    |> halt()
  end
end
