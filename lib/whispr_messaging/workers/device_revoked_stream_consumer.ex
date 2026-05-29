defmodule WhisprMessaging.Workers.DeviceRevokedStreamConsumer do
  @moduledoc """
  Consumer Redis Stream pour les evenements `device.revoked` emis par auth-service
  quand un utilisateur supprime/revoque un appareil depuis ses reglages.

  A la reception, on ferme la session temps-reel de l'appareil cible : on
  broadcast `device_revoked` sur `user:<userId>`. Seule la socket dont
  `socket.assigns.device_id` correspond se ferme (cf `UserChannel.handle_out/3`),
  les autres appareils du meme user ne sont pas impactes.

  Stream : `stream:device.revoked`
  Consumer group : `messaging-service`
  Memes garanties que `UserRegisteredStreamConsumer` : groupe cree au boot
  (MKSTREAM), rejeu de la PEL apres un crash, XACK uniquement sur succes.
  """

  use GenServer
  require Logger

  @stream "stream:device.revoked"
  @group "messaging-service"
  @read_count 16
  @block_ms 5_000
  @error_backoff_ms 1_000
  @max_drain_retries 5

  # --- API publique ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Callbacks GenServer ---

  @impl true
  def init(_opts) do
    if Application.get_env(:whispr_messaging, :env) == :test do
      {:ok, %{redis: nil, running: false}}
    else
      redis_opts = WhisprMessaging.RedisConfig.build()

      case Redix.start_link(redis_opts) do
        {:ok, redis} ->
          send(self(), :start_consume)
          {:ok, %{redis: redis, running: true}}

        {:error, reason} ->
          Logger.error("[DeviceRevokedStreamConsumer] Connexion Redis echouee: #{inspect(reason)}")
          Process.send_after(self(), :retry_connect, 5_000)
          {:ok, %{redis: nil, running: false}}
      end
    end
  end

  @impl true
  def handle_info(:start_consume, %{redis: redis} = state) when not is_nil(redis) do
    :ok = ensure_group(redis)
    :ok = drain_pending(redis, state)
    send(self(), :consume_loop)
    {:noreply, state}
  end

  def handle_info(:start_consume, state) do
    {:noreply, state}
  end

  def handle_info(:consume_loop, %{redis: redis, running: true} = state) when not is_nil(redis) do
    case Redix.command(redis, [
           "XREADGROUP",
           "GROUP",
           @group,
           consumer_name(),
           "COUNT",
           @read_count,
           "BLOCK",
           @block_ms,
           "STREAMS",
           @stream,
           ">"
         ]) do
      {:ok, result} ->
        result |> extract_messages() |> process_messages(redis)
        send(self(), :consume_loop)

      {:error, reason} ->
        Logger.debug("[DeviceRevokedStreamConsumer] XREADGROUP timeout (normal): #{inspect(reason)}")
        Process.send_after(self(), :consume_loop, @error_backoff_ms)
    end

    {:noreply, state}
  end

  def handle_info(:consume_loop, state) do
    {:noreply, state}
  end

  def handle_info(:retry_connect, _state) do
    Logger.info("[DeviceRevokedStreamConsumer] Nouvelle tentative de connexion Redis...")
    {:stop, :normal, %{redis: nil, running: false}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{redis: redis}) when not is_nil(redis) do
    Redix.stop(redis)
  end

  def terminate(_reason, _state), do: :ok

  # --- Logique interne ---

  @doc """
  Cree le consumer group s'il n'existe pas encore.
  MKSTREAM materialise le stream meme avant le premier XADD.
  """
  @spec ensure_group(pid()) :: :ok
  def ensure_group(redis) do
    case Redix.command(redis, ["XGROUP", "CREATE", @stream, @group, "$", "MKSTREAM"]) do
      {:ok, _} ->
        Logger.info("[DeviceRevokedStreamConsumer] Groupe '#{@group}' cree sur '#{@stream}'")
        :ok

      {:error, %Redix.Error{message: "BUSYGROUP" <> _}} ->
        Logger.debug("[DeviceRevokedStreamConsumer] Groupe '#{@group}' existe deja sur '#{@stream}'")
        :ok

      {:error, reason} ->
        Logger.error("[DeviceRevokedStreamConsumer] XGROUP CREATE echoue: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Relit les messages de la PEL (id='0') pour rattraper un crash precedent.
  S'arrete quand la PEL est vide ou apres MAX_DRAIN_RETRIES tentatives sans progres.
  """
  @spec drain_pending(pid(), map()) :: :ok
  def drain_pending(redis, _state, retries \\ 0)

  def drain_pending(_redis, _state, @max_drain_retries) do
    Logger.warning(
      "[DeviceRevokedStreamConsumer] drain_pending: aucun progres apres #{@max_drain_retries} tentatives, bascule sur consume_loop"
    )

    :ok
  end

  def drain_pending(redis, state, retries) do
    case Redix.command(redis, [
           "XREADGROUP",
           "GROUP",
           @group,
           consumer_name(),
           "COUNT",
           @read_count,
           "STREAMS",
           @stream,
           "0"
         ]) do
      {:ok, result} ->
        messages = extract_messages(result)

        if messages == [] do
          :ok
        else
          acked = process_messages(messages, redis)

          if acked == 0 do
            backoff = @error_backoff_ms * Integer.pow(2, retries)
            Process.sleep(backoff)
            drain_pending(redis, state, retries + 1)
          else
            drain_pending(redis, state, 0)
          end
        end

      {:error, reason} ->
        Logger.error("[DeviceRevokedStreamConsumer] drain_pending XREADGROUP echoue: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Traite un batch de messages. Retourne le nombre de messages XACKes.
  Les messages en echec restent en PEL pour le prochain drain_pending.

  `xack_fn` et `broadcast_fn` sont injectables via config (`:device_revoked_xack_fn`
  et `:device_revoked_broadcast_fn`) pour les tests, ce qui evite de dependre
  d'un Redix reel et de l'Endpoint Phoenix dans la suite unitaire.
  """
  @spec process_messages(list(), pid()) :: non_neg_integer()
  def process_messages(messages, redis) do
    xack = xack_fn()
    broadcast = broadcast_fn()

    Enum.reduce(messages, 0, fn [id | fields_flat], acked ->
      fields = parse_fields(fields_flat)

      case revoke_device(fields, broadcast) do
        :ok ->
          xack.(redis, @stream, @group, id)
          acked + 1

        {:error, reason} ->
          Logger.error("[DeviceRevokedStreamConsumer] Echec traitement message #{id}: #{inspect(reason)}")
          acked
      end
    end)
  end

  @doc """
  Diffuse l'ordre de fermeture vers `user:<userId>`. La socket de l'appareil
  cible se ferme elle-meme (filtrage par `device_id` cote channel).
  """
  @spec revoke_device(map(), (String.t(), String.t(), map() -> term())) ::
          :ok | {:error, term()}
  def revoke_device(%{"userId" => user_id, "deviceId" => device_id}, broadcast)
      when is_binary(user_id) and user_id != "" and is_binary(device_id) and device_id != "" do
    broadcast.("user:#{user_id}", "device_revoked", %{device_id: device_id})

    Logger.info(
      "[DeviceRevokedStreamConsumer] device_revoked broadcast user_id=#{user_id} device_id=#{device_id}"
    )

    :ok
  end

  def revoke_device(fields, _broadcast) do
    {:error, {:invalid_fields, fields}}
  end

  defp xack_fn do
    Application.get_env(
      :whispr_messaging,
      :device_revoked_xack_fn,
      fn redis, stream, group, id -> Redix.command(redis, ["XACK", stream, group, id]) end
    )
  end

  defp broadcast_fn do
    Application.get_env(
      :whispr_messaging,
      :device_revoked_broadcast_fn,
      fn topic, event, payload -> WhisprMessagingWeb.Endpoint.broadcast(topic, event, payload) end
    )
  end

  # --- Helpers prives ---

  defp consumer_name do
    System.get_env("HOSTNAME") || "messaging-service-#{System.pid()}"
  end

  # Transforme la reponse brute XREADGROUP en liste de messages.
  # Format Redis : [[stream_name, [[id, [k1,v1,k2,v2,...]], ...]]]
  @spec extract_messages(term()) :: list()
  def extract_messages(nil), do: []
  def extract_messages([]), do: []

  def extract_messages([[_stream, messages]]) when is_list(messages) do
    Enum.map(messages, fn [id | fields_nested] ->
      [id | List.flatten(fields_nested)]
    end)
  end

  def extract_messages(_), do: []

  # Convertit une liste plate [k, v, k, v] en map %{k => v}.
  @spec parse_fields(list(String.t())) :: map()
  def parse_fields(flat_list) do
    flat_list
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [k, v], acc -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
