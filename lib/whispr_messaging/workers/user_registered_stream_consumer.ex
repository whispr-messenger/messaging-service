defmodule WhisprMessaging.Workers.UserRegisteredStreamConsumer do
  @moduledoc """
  Consumer Redis Stream pour les evenements `user.registered` emis par auth-service.

  Remplace le pattern Pub/Sub qui perdait les messages si ce pod etait down
  au moment de l'inscription. Avec les Streams, les messages sont persistes
  et relus a chaque demarrage via la PEL (Pending Entry List).

  Stream : `stream:user.registered`
  Consumer group : `messaging-service`
  Comportement :
    1. Au demarrage, cree le groupe si absent (MKSTREAM).
    2. Rejoue les messages en attente (PEL) du precedent run (drain_pending).
    3. Entre dans une boucle XREADGROUP bloquante pour les nouveaux messages.
    4. Chaque message traite avec succes est XACK. Les echecs restent en PEL
       et seront rejoues au prochain redemarrage du pod.
  """

  use GenServer
  require Logger

  alias WhisprMessaging.Accounts.User
  alias WhisprMessaging.Repo

  @stream "stream:user.registered"
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
          Logger.error(
            "[UserRegisteredStreamConsumer] Connexion Redis echouee: #{inspect(reason)}"
          )

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
        Logger.debug(
          "[UserRegisteredStreamConsumer] XREADGROUP timeout (normal): #{inspect(reason)}"
        )

        Process.send_after(self(), :consume_loop, @error_backoff_ms)
    end

    {:noreply, state}
  end

  def handle_info(:consume_loop, state) do
    {:noreply, state}
  end

  def handle_info(:retry_connect, _state) do
    Logger.info("[UserRegisteredStreamConsumer] Nouvelle tentative de connexion Redis...")
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
        Logger.info("[UserRegisteredStreamConsumer] Groupe '#{@group}' cree sur '#{@stream}'")
        :ok

      {:error, %Redix.Error{message: "BUSYGROUP" <> _}} ->
        Logger.debug(
          "[UserRegisteredStreamConsumer] Groupe '#{@group}' existe deja sur '#{@stream}'"
        )

        :ok

      {:error, reason} ->
        Logger.error("[UserRegisteredStreamConsumer] XGROUP CREATE echoue: #{inspect(reason)}")
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
      "[UserRegisteredStreamConsumer] drain_pending: aucun progres apres #{@max_drain_retries} tentatives, bascule sur consume_loop"
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
        Logger.error(
          "[UserRegisteredStreamConsumer] drain_pending XREADGROUP echoue: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc """
  Traite un batch de messages. Retourne le nombre de messages XACKes.
  Les messages en echec restent en PEL pour le prochain drain_pending.

  Le xack_fn est injectable via config (`:xack_fn`) pour les tests, ce qui
  evite de dependre d'un process Redix reel dans la suite de tests unitaires.
  """
  @spec process_messages(list(), pid()) :: non_neg_integer()
  def process_messages(messages, redis) do
    xack = xack_fn()

    Enum.reduce(messages, 0, fn [id | fields_flat], acked ->
      fields = parse_fields(fields_flat)

      case upsert_user(fields) do
        {:ok, _user} ->
          xack.(redis, @stream, @group, id)
          acked + 1

        {:error, reason} ->
          Logger.error(
            "[UserRegisteredStreamConsumer] Echec traitement message #{id}: #{inspect(reason)}"
          )

          acked
      end
    end)
  end

  defp xack_fn do
    Application.get_env(
      :whispr_messaging,
      :user_registered_xack_fn,
      fn redis, stream, group, id -> Redix.command(redis, ["XACK", stream, group, id]) end
    )
  end

  @doc """
  Insere ou ignore un utilisateur dans la projection locale.
  ON CONFLICT DO NOTHING pour l'idempotence (rejeu PEL).
  """
  @spec upsert_user(map()) :: {:ok, User.t()} | {:error, term()}
  def upsert_user(%{"userId" => user_id, "phoneNumber" => phone_number})
      when is_binary(user_id) and user_id != "" and is_binary(phone_number) and phone_number != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.insert(
        %User{id: user_id, phone_number: phone_number, inserted_at: now, updated_at: now},
        on_conflict: :nothing,
        conflict_target: :id
      )

    case result do
      {:ok, user} ->
        Logger.info(
          "[UserRegisteredStreamConsumer] user_id=#{user_id} insere dans la projection locale"
        )

        {:ok, user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def upsert_user(fields) do
    {:error, {:invalid_fields, fields}}
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
