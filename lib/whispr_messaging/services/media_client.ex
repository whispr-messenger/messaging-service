defmodule WhisprMessaging.Services.MediaClient do
  @moduledoc """
  Petit client HTTP pour media-service.

  WHISPR-1256 : quand on serialise les conversations, messaging-service
  doit renvoyer des URLs qu'un client web peut afficher dans
  `<img src>` sans header `Authorization`. L'endpoint
  `/media/v1/:id/blob` exige un JWT, donc ce module forwarde le header
  `Authorization` de l'appelant a media-service et echange l'URL blob
  brute contre l'URL S3 presignee renvoyee par l'endpoint
  (`{ url, expiresAt }`).

  Reprend le pattern du `MediaClientService` cote user-service
  (WHISPR-1253) en version Elixir + Finch. En cas d'erreur on retombe
  sur l'URL d'entree, comme ca un incident media-service ne casse
  jamais la liste des conversations.
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
  # API publique
  # ---------------------------------------------------------------------------

  @doc """
  Remplace chaque valeur sous une cle media reconnue (voir
  `@media_url_keys`) dans la map metadata par une URL S3 presignee.

  On laisse tel quel quand :
    - `metadata` n'est pas une map
    - la valeur n'est pas un binary
    - la valeur ne ressemble pas a `/media/v1/:uuid/(blob|thumbnail)`
    - `authorization` est `nil` ou vide
    - media-service est injoignable ou renvoie une erreur
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
  Renvoie `{:ok, presigned_url}` quand l'URL en entree pointe vers un
  blob media-service et que le presign reussit. Renvoie `:unchanged`
  sinon - dans ce cas l'appelant garde la valeur d'origine.
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
  Demande une URL presignee a media-service. Renvoie `{:ok, url}` en
  cas de succes, `{:error, reason}` sinon.

  - `media_id` : UUID extrait de l'URL blob brute
  - `kind` : `:blob` ou `:thumbnail`
  - `authorization` : valeur brute du header `Authorization`
    (`"Bearer ..."`)
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
  # Gestion du cache (ETS, init lazy)
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
  # Helpers prives
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
        # l'endpoint thumbnail renvoie `{ url: null }` quand il n'y en a pas
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
