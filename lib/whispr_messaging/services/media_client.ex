defmodule WhisprMessaging.Services.MediaClient do
  @moduledoc """
  Lightweight HTTP client for the media-service.

  WHISPR-1256: when serializing conversations the messaging-service must hand
  back URLs that a web client can render in `<img src>` without an
  `Authorization` header. The `/media/v1/:id/blob` endpoint requires a JWT,
  so this module forwards the caller's `Authorization` header to media-service
  and swaps the bare blob URL for the presigned S3 URL the endpoint returns
  (`{ url, expiresAt }`).

  Mirrors the pattern used by user-service `MediaClientService` (WHISPR-1253)
  but in Elixir + Finch. Falls back to the input URL on any error so a
  media-service outage never breaks the conversations list.
  """

  require Logger

  @default_timeout_ms 5_000
  @cache_ttl_ms 60 * 1000
  @cache_table :whispr_messaging_media_presign_cache
  @media_url_regex Regex.compile!(
                     "/media/v1/(?:public/)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/(blob|thumbnail)(?:\\?.*)?$"
                   )

  @media_url_keys ~w(
    avatar_url
    group_avatar_url
    group_icon_url
    icon_url
    image_url
    photo_url
    picture_url
    thumbnail_url
  )

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Replaces every value under a recognised media key (see `@media_url_keys`)
  in the given metadata map by a presigned S3 URL.

  Untouched when:
    - `metadata` is not a map
    - the value is not a binary
    - the value does not look like `/media/v1/:uuid/(blob|thumbnail)`
    - `authorization` is `nil` or empty
    - media-service is unreachable / returns an error
  """
  def presign_metadata_urls(metadata, authorization)

  def presign_metadata_urls(metadata, _authorization) when not is_map(metadata) do
    metadata
  end

  def presign_metadata_urls(metadata, authorization) do
    Enum.reduce(metadata, metadata, fn {key, value}, acc ->
      cond do
        not is_binary(value) ->
          acc

        not media_url_key?(key) ->
          acc

        true ->
          case maybe_presign_url(value, authorization) do
            {:ok, presigned} -> Map.put(acc, key, presigned)
            :unchanged -> acc
          end
      end
    end)
  end

  @doc """
  Returns `{:ok, presigned_url}` when the input URL points to a media-service
  blob and the presign call succeeds. Returns `:unchanged` otherwise — caller
  keeps the original value.
  """
  def maybe_presign_url(url, authorization) when is_binary(url) do
    case extract_media_id(url) do
      {:ok, media_id, kind} ->
        case presign(media_id, kind, authorization) do
          {:ok, presigned} -> {:ok, presigned}
          {:error, _reason} -> :unchanged
        end

      :error ->
        :unchanged
    end
  end

  def maybe_presign_url(_url, _authorization), do: :unchanged

  @doc """
  Asks media-service for a presigned URL. Returns `{:ok, url}` on success,
  `{:error, reason}` otherwise.

  - `media_id` — the UUID extracted from the bare blob URL
  - `kind` — `:blob` or `:thumbnail`
  - `authorization` — the raw `Authorization` header value (`"Bearer ..."`)
  """
  def presign(media_id, kind, authorization)
      when is_binary(media_id) and kind in [:blob, :thumbnail] do
    if is_binary(authorization) and authorization != "" do
      case cache_get(media_id, kind) do
        {:ok, cached} -> {:ok, cached}
        :miss -> do_presign(media_id, kind, authorization)
      end
    else
      {:error, :missing_authorization}
    end
  end

  # ---------------------------------------------------------------------------
  # Cache management (ETS, lazy initialised)
  # ---------------------------------------------------------------------------

  @doc false
  def ensure_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  @doc false
  def reset_cache do
    ensure_cache()
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  defp cache_get(media_id, kind) do
    ensure_cache()
    key = {media_id, kind}

    case :ets.lookup(@cache_table, key) do
      [{^key, url, expires_at_ms}] ->
        if expires_at_ms > now_ms() do
          {:ok, url}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(media_id, kind, url) do
    ensure_cache()
    :ets.insert(@cache_table, {{media_id, kind}, url, now_ms() + cache_ttl_ms()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_presign(media_id, kind, authorization) do
    url = presign_endpoint(media_id, kind)
    headers = [{"accept", "application/json"}, {"authorization", authorization}]

    :get
    |> Finch.build(url, headers)
    |> Finch.request(WhisprMessaging.Finch, receive_timeout: timeout_ms())
    |> handle_response(media_id, kind)
  end

  defp handle_response({:ok, %Finch.Response{status: 200, body: body}}, media_id, kind) do
    case Jason.decode(body) do
      {:ok, %{"url" => presigned_url}} when is_binary(presigned_url) ->
        cache_put(media_id, kind, presigned_url)
        {:ok, presigned_url}

      {:ok, %{"url" => nil}} ->
        # Thumbnail endpoint returns `{ url: null }` when none is stored.
        {:error, :no_media}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, media_id, _kind)
       when status in [401, 403] do
    Logger.warning("media-service rejected presign call",
      status: status,
      media_id: media_id,
      domain: :media_service
    )

    {:error, :unauthorized}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, media_id, _kind)
       when status >= 500 do
    Logger.warning("media-service 5xx on presign",
      status: status,
      media_id: media_id,
      domain: :media_service
    )

    {:error, :transient}
  end

  defp handle_response({:ok, %Finch.Response{status: status}}, media_id, _kind) do
    Logger.warning("media-service unexpected status on presign",
      status: status,
      media_id: media_id,
      domain: :media_service
    )

    {:error, :request_failed}
  end

  defp handle_response({:error, reason}, media_id, _kind) do
    Logger.warning("media-service request failed",
      reason: inspect(reason),
      media_id: media_id,
      domain: :media_service
    )

    {:error, :transient}
  end

  defp presign_endpoint(media_id, kind) do
    base_url() <> "/media/v1/" <> URI.encode(media_id) <> "/" <> Atom.to_string(kind)
  end

  defp extract_media_id(url) do
    case Regex.run(@media_url_regex, url) do
      [_, media_id, "blob"] -> {:ok, media_id, :blob}
      [_, media_id, "thumbnail"] -> {:ok, media_id, :thumbnail}
      _ -> :error
    end
  end

  defp media_url_key?(key) when is_atom(key), do: media_url_key?(Atom.to_string(key))
  defp media_url_key?(key) when is_binary(key), do: key in @media_url_keys
  defp media_url_key?(_), do: false

  defp base_url do
    config = Application.get_env(:whispr_messaging, :media_service_internal, [])

    Keyword.get(config, :url) ||
      System.get_env("MEDIA_SERVICE_HTTP_URL") ||
      "http://media-service:3013"
  end

  defp timeout_ms do
    config = Application.get_env(:whispr_messaging, :media_service_internal, [])
    Keyword.get(config, :timeout_ms, @default_timeout_ms)
  end

  defp cache_ttl_ms do
    config = Application.get_env(:whispr_messaging, :media_service_internal, [])
    Keyword.get(config, :cache_ttl_ms, @cache_ttl_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
