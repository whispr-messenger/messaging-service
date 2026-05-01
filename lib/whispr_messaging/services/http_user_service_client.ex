defmodule WhisprMessaging.Services.HttpUserServiceClient do
  @moduledoc """
  Real implementation of `WhisprMessaging.Services.UserServiceBehaviour` that
  talks to user-service over HTTP using the shared `x-internal-token` secret.

  The base URL and token are read from
  `Application.get_env(:whispr_messaging, :user_service_internal)` (see
  `config/runtime.exs`), with env-var fallbacks `USER_SERVICE_INTERNAL_URL` and
  `INTERNAL_API_TOKEN`.
  """

  @behaviour WhisprMessaging.Services.UserServiceBehaviour

  require Logger

  alias WhisprMessaging.Services.UserService

  @default_timeout_ms 5_000

  @doc """
  Best-effort existence check.

  user-service does not expose a dedicated `/users/:id/exists` endpoint today,
  so we proxy via a self-paired call to `/internal/v1/contacts/check?ownerId=&
  contactId=`. That endpoint always returns `200` (cf. user-service
  `InternalContactsController` swagger doc), regardless of whether the user
  exists. As a result this function effectively becomes a health-check of
  user-service rather than a true existence check.

  Behaviour:

    * HTTP 200 → `{:ok, true}` (user-service is reachable; we cannot prove
      non-existence with the current contract).
    * 401/403 → `{:error, :unauthorized}` (token mismatch — logged at error
      level).
    * 5xx, timeout, network error → `{:error, :transient}` (caller decides
      whether to retry or fail-closed).

  Follow-up: a dedicated existence endpoint should be added on user-service to
  return 404 when the id is unknown. Tracked as a separate Jira ticket linked
  from WHISPR-840.
  """
  @impl true
  def check_user_exists(user_id) do
    user = String.trim(to_string(user_id))

    case do_check(user, user) do
      {:ok, _payload} ->
        {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns `{:ok, true}` when either user has blocked the other, `{:ok, false}`
  when neither has, and `{:error, _}` on any failure.

  Fail-safe policy: callers MUST treat `{:error, _}` as fail-closed (assume
  blocked) — we do not return `{:ok, false}` on transient errors because that
  would silently let blocked users initiate conversations whenever user-service
  is degraded. The `with` chain in `WhisprMessaging.Conversations
  .do_create_direct_conversation/3` already propagates the error, which short-
  circuits the conversation creation.
  """
  @impl true
  def check_user_blocked(blocker_id, blocked_id) do
    blocker = String.trim(to_string(blocker_id))
    blocked = String.trim(to_string(blocked_id))

    case do_check(blocker, blocked) do
      {:ok, %{"isBlocked" => is_blocked}} ->
        {:ok, is_blocked == true}

      {:ok, _payload} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_check(owner_id, contact_id) do
    url =
      UserService.internal_base_url() <>
        "/contacts/check?ownerId=" <>
        URI.encode_www_form(owner_id) <>
        "&contactId=" <> URI.encode_www_form(contact_id)

    :get
    |> Finch.build(url, build_headers())
    |> Finch.request(WhisprMessaging.Finch, receive_timeout: timeout_ms())
    |> handle_response()
  end

  defp build_headers do
    base = [{"accept", "application/json"}]

    case UserService.internal_token() do
      token when is_binary(token) and token != "" ->
        base ++ [{"x-internal-token", token}]

      _ ->
        base
    end
  end

  defp handle_response({:ok, %Finch.Response{status: 200, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, :invalid_response}
    end
  end

  defp handle_response({:ok, %Finch.Response{status: status}})
       when status in [401, 403] do
    Logger.error("user-service rejected internal token",
      status: status,
      domain: :user_service
    )

    {:error, :unauthorized}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}) when status >= 500 do
    Logger.warning("user-service 5xx on internal contacts check",
      status: status,
      domain: :user_service
    )

    {:error, :transient}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}) do
    Logger.warning("user-service unexpected status on internal contacts check",
      status: status,
      domain: :user_service
    )

    {:error, :request_failed}
  end

  defp handle_response({:error, %{__struct__: _} = reason}) do
    Logger.warning("user-service request failed",
      reason: inspect(reason),
      domain: :user_service
    )

    {:error, :transient}
  end

  defp handle_response({:error, reason}) do
    Logger.warning("user-service request failed",
      reason: inspect(reason),
      domain: :user_service
    )

    {:error, :transient}
  end

  defp timeout_ms do
    config = Application.get_env(:whispr_messaging, :user_service_internal, [])
    Keyword.get(config, :timeout_ms, @default_timeout_ms)
  end
end
