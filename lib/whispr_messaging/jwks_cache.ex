defmodule WhisprMessaging.JwksCache do
  @moduledoc """
  GenServer that fetches and caches the JWKS public keys from the auth-service
  at startup and periodically refreshes them.

  The signing public key is cached as a `JOSE.JWK` struct so that JWT
  verification can be performed without a network call on every request.

  Configuration (runtime.exs / env):
  - `JWT_JWKS_URL`: URL of the JWKS endpoint (default: http://auth-service/auth/.well-known/jwks.json)
  - `JWT_JWKS_REFRESH_MS`: how often to refresh the key (default: 3_600_000 ms = 1 h)

  The fetch is non-fatal at startup: if the JWKS endpoint is unreachable the
  server starts anyway and retries after `JWT_JWKS_REFRESH_MS` milliseconds.
  JWT validation will fail until the key is loaded.
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

  @doc "Returns `{:ok, jose_jwk}` or `{:error, :not_loaded}`."
  def get_signing_key do
    case GenServer.call(__MODULE__, :get_signing_key) do
      nil -> {:error, :not_loaded}
      jwk -> {:ok, jwk}
    end
  end

  # ─────────────────────────────────────────────── Server callbacks ────────────

  @impl true
  def init(_opts) do
    url = System.get_env("JWT_JWKS_URL", @default_jwks_url)
    refresh_ms =
      System.get_env("JWT_JWKS_REFRESH_MS", "#{@default_refresh_ms}") |> String.to_integer()
    state = %{url: url, refresh_ms: refresh_ms, jwk: nil}
    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_signing_key, _from, state) do
    {:reply, state.jwk, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    new_jwk =
      case fetch_signing_key(state.url) do
        {:ok, jwk} ->
          Logger.info("[JwksCache] ES256 public key loaded from #{state.url}")
          jwk

        {:error, reason} ->
          Logger.error("[JwksCache] Failed to load JWKS: #{inspect(reason)}")
          state.jwk
      end

    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, %{state | jwk: new_jwk}}
  end

  # ─────────────────────────────────────────────── Private ─────────────────────

  defp fetch_signing_key(url) do
    case Finch.build(:get, url)
         |> Finch.request(WhisprMessaging.Finch, receive_timeout: @fetch_timeout_ms) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        with {:ok, doc} <- Jason.decode(body),
             {:ok, jwk} <- extract_ec_key(doc) do
          {:ok, jwk}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "JWKS endpoint returned HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_ec_key(%{"keys" => keys}) when is_list(keys) do
    case Enum.find(keys, fn k ->
           k["kty"] == "EC" and k["crv"] == "P-256" and
             (k["use"] == "sig" or k["alg"] == "ES256")
         end) do
      nil ->
        {:error, "No ES256 (EC P-256) key found in JWKS document"}

      key_map ->
        try do
          jwk = JOSE.JWK.from_map(key_map)
          {:ok, jwk}
        rescue
          e -> {:error, "Failed to import EC key: #{inspect(e)}"}
        end
    end
  end

  defp extract_ec_key(_), do: {:error, "Invalid JWKS document"}
end
