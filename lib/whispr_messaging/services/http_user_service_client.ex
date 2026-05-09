defmodule WhisprMessaging.Services.HttpUserServiceClient do
  @moduledoc """
  Implementation reelle de `WhisprMessaging.Services.UserServiceBehaviour`
  qui dialogue avec user-service en HTTP via le secret partage
  `x-internal-token`.

  L'URL de base et le token viennent de
  `Application.get_env(:whispr_messaging, :user_service_internal)` (cf.
  `config/runtime.exs`), avec fallback sur les env vars
  `USER_SERVICE_INTERNAL_URL` et `INTERNAL_API_TOKEN`.
  """

  @behaviour WhisprMessaging.Services.UserServiceBehaviour

  require Logger

  alias WhisprMessaging.Services.UserService

  @default_timeout_ms 5_000

  # WHISPR-1304: cache court (60s) pour eviter de hammer user-service
  # a chaque mark_read. Le pattern est repris du `media_client.ex`
  # (ETS named_table, init lazy via `ensure_cache/0`). 60s est un
  # compromis entre reactivite quand l'utilisateur change ses
  # privacy settings et nombre d'aller-retours en chat actif.
  @privacy_cache_ttl_ms 60 * 1000
  @privacy_cache_table :whispr_messaging_user_privacy_cache

  @doc """
  Verification d'existence en best-effort.

  user-service n'expose pas aujourd'hui d'endpoint dedie
  `/users/:id/exists`. On passe donc par un appel self-paire a
  `/internal/v1/contacts/check?ownerId=&contactId=`. Cet endpoint repond
  toujours `200` (cf. doc swagger du `InternalContactsController` cote
  user-service), que l'utilisateur existe ou pas. Du coup cette fonction
  fait surtout un healthcheck de user-service et pas une vraie verif
  d'existence.

  Comportement :

    * HTTP 200 -> `{:ok, true}` (user-service est joignable, on ne peut
      pas prouver la non-existence avec le contrat actuel).
    * 401/403 -> `{:error, :unauthorized}` (token qui ne matche pas, log
      en error).
    * 5xx, timeout, erreur reseau -> `{:error, :transient}` (a l'appelant
      de decider entre retry ou fail-closed).

  A faire plus tard : ajouter un endpoint d'existence dedie cote
  user-service qui renvoie 404 quand l'id est inconnu. Suivi sur un
  ticket Jira distinct lie a WHISPR-840.
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
  Renvoie `{:ok, true}` si l'un des deux utilisateurs a bloque l'autre,
  `{:ok, false}` si aucun des deux ne l'a fait, et `{:error, _}` en cas
  d'echec.

  Politique fail-safe : les appelants DOIVENT traiter `{:error, _}` comme
  fail-closed (considerer comme bloque). On ne renvoie pas `{:ok, false}`
  sur erreur transitoire, sinon des utilisateurs bloques pourraient
  initier des conversations silencieusement quand user-service est
  degrade. La chaine `with` dans
  `WhisprMessaging.Conversations.do_create_direct_conversation/3`
  propage deja l'erreur et court-circuite la creation.
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

  @doc """
  Recupere les flags de privacy d'un utilisateur via
  `GET /internal/users/:id/privacy`. Renvoie `{:ok, %{read_receipts: bool, ...}}`
  en cas de succes.

  WHISPR-1304: utilise par le gating WhatsApp punitive avant de
  broadcast `message_read`/`message_unread`. Sur erreur transitoire,
  l'appelant doit fail-open (broadcast quand meme) - une indispo de
  user-service ne doit pas casser les read receipts d'un user qui a
  active la fonctionnalite.

  Cache ETS 60s par user_id pour eviter un round-trip HTTP a chaque
  ack de lecture en chat actif.
  """
  @impl true
  def get_privacy_settings(user_id) do
    user = String.trim(to_string(user_id))

    case cache_get(user) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        case do_get_privacy(user) do
          {:ok, settings} ->
            cache_put(user, settings)
            {:ok, settings}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  def ensure_privacy_cache do
    case :ets.whereis(@privacy_cache_table) do
      :undefined ->
        try do
          :ets.new(@privacy_cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  @doc false
  def reset_privacy_cache do
    ensure_privacy_cache()
    :ets.delete_all_objects(@privacy_cache_table)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers prives
  # ---------------------------------------------------------------------------

  defp do_get_privacy(user_id) do
    url =
      UserService.internal_base_url() <>
        "/users/" <> URI.encode(user_id) <> "/privacy"

    :get
    |> Finch.build(url, build_headers())
    |> Finch.request(WhisprMessaging.Finch, receive_timeout: timeout_ms())
    |> handle_privacy_response()
  end

  defp handle_privacy_response({:ok, %Finch.Response{status: 200, body: body}}) do
    case Jason.decode(body) do
      {:ok, %{} = json} ->
        {:ok, normalize_privacy(json)}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp handle_privacy_response({:ok, %Finch.Response{status: 404}}) do
    # User inconnu cote user-service: on traite ca comme transient
    # plutot que de cacher un faux "fail-open" sous un :ok. L'appelant
    # decide de broadcast ou non.
    {:error, :not_found}
  end

  defp handle_privacy_response({:ok, %Finch.Response{status: status}})
       when status in [401, 403] do
    Logger.error("user-service rejected internal token on privacy fetch",
      status: status,
      domain: :user_service
    )

    {:error, :unauthorized}
  end

  defp handle_privacy_response({:ok, %Finch.Response{status: status}}) when status >= 500 do
    Logger.warning("user-service 5xx on privacy fetch",
      status: status,
      domain: :user_service
    )

    {:error, :transient}
  end

  defp handle_privacy_response({:ok, %Finch.Response{status: status}}) do
    Logger.warning("user-service unexpected status on privacy fetch",
      status: status,
      domain: :user_service
    )

    {:error, :request_failed}
  end

  defp handle_privacy_response({:error, %{__struct__: _} = reason}) do
    Logger.warning("user-service privacy request failed",
      reason: inspect(reason),
      domain: :user_service
    )

    {:error, :transient}
  end

  defp handle_privacy_response({:error, reason}) do
    Logger.warning("user-service privacy request failed",
      reason: inspect(reason),
      domain: :user_service
    )

    {:error, :transient}
  end

  # camelCase (NestJS) -> snake_case (Elixir). On garde uniquement les
  # cles connues du DTO user-service (cf. PR #127) pour eviter un
  # atom-leak depuis le payload externe.
  # Format DTO :
  #   { userId, readReceipts: bool,
  #     lastSeenPrivacy: "everyone"|"contacts"|"nobody",
  #     onlineStatus: "everyone"|"contacts"|"nobody" }
  defp normalize_privacy(json) do
    %{
      read_receipts: extract_bool(json, "readReceipts", true),
      last_seen_privacy: extract_privacy_enum(json, "lastSeenPrivacy"),
      online_status: extract_privacy_enum(json, "onlineStatus")
    }
  end

  defp extract_privacy_enum(json, key) do
    case Map.get(json, key) do
      v when v in ["everyone", "contacts", "nobody"] -> v
      _ -> nil
    end
  end

  defp extract_bool(json, key, default) do
    case Map.get(json, key, default) do
      v when is_boolean(v) -> v
      _ -> default
    end
  end

  defp cache_get(user_id) do
    ensure_privacy_cache()

    case :ets.lookup(@privacy_cache_table, user_id) do
      [{^user_id, settings, expires_at_ms}] ->
        if expires_at_ms > now_ms() do
          {:ok, settings}
        else
          :ets.delete(@privacy_cache_table, user_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(user_id, settings) do
    ensure_privacy_cache()
    :ets.insert(@privacy_cache_table, {user_id, settings, now_ms() + privacy_cache_ttl_ms()})
    :ok
  end

  defp privacy_cache_ttl_ms do
    config = Application.get_env(:whispr_messaging, :user_service_internal, [])
    Keyword.get(config, :privacy_cache_ttl_ms, @privacy_cache_ttl_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

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
