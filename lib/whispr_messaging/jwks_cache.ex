defmodule WhisprMessaging.JwksCache do
  @moduledoc """
  GenServer that fetches and caches the JWKS public keys from the auth-service
  at startup and periodically refreshes them.

  Keys are cached as a map of `kid => pem_string` so that:
  - JWT verification requires no network call on the hot path
  - Key rotation is handled transparently: all keys present in the JWKS
    response are cached simultaneously, allowing in-flight JWTs signed with
    the previous key to remain valid during rotation

  Configuration (read from `Application.get_env(:whispr_messaging, :jwks)` —
  set in `config/runtime.exs`):
  - `:url` — JWKS endpoint URL (default: http://auth-service/auth/.well-known/jwks.json)
  - `:refresh_ms` — how often to refresh the keys (default: 3_600_000 ms = 1 h)

  The fetch is non-fatal at startup: if the JWKS endpoint is unreachable the
  server starts anyway and retries after `:refresh_ms` milliseconds.
  JWT validation will fail until at least one key is loaded.
  """

  use GenServer
  require Logger

  @default_jwks_url "http://auth-service/auth/.well-known/jwks.json"
  @default_refresh_ms 3_600_000
  @fetch_timeout_ms 5_000

  # ─────────────────────────────────────────────── Client API ──────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, pem_string}` for the given `kid`, or the first cached key if
  `kid` is `nil`.  Returns `{:error, :not_loaded}` when no keys are available.
  """
  def get_signing_key(kid \\ nil) do
    case GenServer.call(__MODULE__, {:get_signing_key, kid}) do
      nil -> {:error, :not_loaded}
      pem -> {:ok, pem}
    end
  end

  # ─────────────────────────────────────────────── Server callbacks ────────────

  @impl true
  def init(opts) do
    # Prefer injected opts (useful for tests), fall back to Application config,
    # then module-level defaults.
    jwks_cfg = Application.get_env(:whispr_messaging, :jwks, [])

    url = Keyword.get(opts, :url, Keyword.get(jwks_cfg, :url, @default_jwks_url))

    refresh_ms =
      Keyword.get(opts, :refresh_ms, Keyword.get(jwks_cfg, :refresh_ms, @default_refresh_ms))

    state = %{url: url, refresh_ms: refresh_ms, keys: %{}}
    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call({:get_signing_key, nil}, _from, %{keys: keys} = state) do
    pem = keys |> Map.values() |> List.first()
    {:reply, pem, state}
  end

  def handle_call({:get_signing_key, kid}, _from, %{keys: keys} = state) do
    {:reply, Map.get(keys, kid), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    new_keys =
      case fetch_signing_keys(state.url) do
        {:ok, keys} when map_size(keys) > 0 ->
          Logger.info("[JwksCache] Loaded #{map_size(keys)} EC P-256 key(s) from #{state.url}")
          keys

        {:ok, _empty} ->
          Logger.error("[JwksCache] JWKS document contained no usable EC P-256 keys")
          state.keys

        {:error, reason} ->
          Logger.error("[JwksCache] Failed to load JWKS: #{inspect(reason)}")
          state.keys
      end

    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, %{state | keys: new_keys}}
  end

  # ─────────────────────────────────────────────── Private ─────────────────────

  defp fetch_signing_keys(url) do
    case Finch.build(:get, url)
         |> Finch.request(WhisprMessaging.Finch, receive_timeout: @fetch_timeout_ms) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, doc} <- Jason.decode(body) do
          extract_ec_keys(doc)
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "JWKS endpoint returned HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns `{:ok, %{kid => pem_string}}` for all valid EC P-256 signing keys.
  defp extract_ec_keys(%{"keys" => keys}) when is_list(keys) do
    result =
      keys
      |> Enum.filter(fn k ->
        k["kty"] == "EC" and k["crv"] == "P-256" and
          (k["use"] == "sig" or k["alg"] == "ES256")
      end)
      |> Enum.reduce(%{}, fn key_map, acc ->
        try do
          {_, pem} = key_map |> JOSE.JWK.from_map() |> JOSE.JWK.to_pem()
          kid = Map.get(key_map, "kid", "key-#{map_size(acc)}")
          Map.put(acc, kid, pem)
        rescue
          e ->
            Logger.warning("[JwksCache] Skipping unreadable EC key: #{inspect(e)}")
            acc
        end
      end)

    {:ok, result}
  end

  defp extract_ec_keys(_), do: {:error, "Invalid JWKS document"}
end
