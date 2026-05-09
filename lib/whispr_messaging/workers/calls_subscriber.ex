defmodule WhisprMessaging.Workers.CallsSubscriber do
  @moduledoc """
  Redis pub/sub subscriber that relays calls-service events to the per-user
  Phoenix channels hosted by this service.

  Subscribes to:
    * `whispr:calls:initiated`       — caller issued POST /calls, LiveKit room provisioned.
    * `whispr:calls:participant_left` — LiveKit webhook: a participant left the room.

  Rebroadcasts as `incoming_call` on `user:<callee_id>` for every participant
  other than the initiator, so `useWebSocket.ts` in mobile-app can open the
  IncomingCallScreen without any additional transport.

  Lives here (not in calls-service) because messaging-service owns the
  Phoenix.Endpoint that mobile-app actually holds a websocket to. Pattern
  copied from `WhisprMessaging.Workers.ModerationSubscriber`.

  Follow-up: `whispr:calls:{accepted,declined,ended}` payloads only carry
  `call_id` today, so relaying them to the initiator/participants would
  require either augmenting the calls-service publisher or caching
  participants here. Left out of this change — see WHISPR-1167 follow-up.
  """

  use GenServer
  require Logger

  alias WhisprMessaging.Conversations.Conversation
  alias WhisprMessaging.Repo

  @channels ["whispr:calls:initiated", "whispr:calls:participant_left"]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    redis_opts = WhisprMessaging.RedisConfig.build()

    case Redix.PubSub.start_link(redis_opts) do
      {:ok, pubsub} ->
        for channel <- @channels do
          Redix.PubSub.subscribe(pubsub, channel, self())
        end

        Logger.info("[CallsSubscriber] Subscribed to #{length(@channels)} calls channels")

        {:ok, %{pubsub: pubsub}}

      {:error, reason} ->
        Logger.error("[CallsSubscriber] Failed to connect to Redis: #{inspect(reason)}")
        Process.send_after(self(), :retry_connect, 5_000)
        {:ok, %{pubsub: nil}}
    end
  end

  @impl true
  def handle_info(
        {:redix_pubsub, _pubsub, _ref, :subscribed, %{channel: channel}},
        state
      ) do
    Logger.debug("[CallsSubscriber] Subscribed to #{channel}")
    {:noreply, state}
  end

  def handle_info(
        {:redix_pubsub, _pubsub, _ref, :message, %{channel: channel, payload: payload}},
        state
      ) do
    Task.Supervisor.start_child(WhisprMessaging.TaskSupervisor, fn ->
      handle_message(channel, payload)
    end)

    {:noreply, state}
  end

  def handle_info(:retry_connect, state) do
    Logger.info("[CallsSubscriber] Retrying Redis connection…")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_message(channel, raw_payload) do
    case Jason.decode(raw_payload) do
      {:ok, payload} ->
        route_event(channel, payload)

      {:error, reason} ->
        Logger.error(
          "[CallsSubscriber] Failed to decode payload on #{channel}: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.error("[CallsSubscriber] Error handling #{channel}: #{inspect(error)}")
  end

  defp route_event("whispr:calls:initiated", payload),
    do: broadcast_incoming_call(payload)

  defp route_event("whispr:calls:participant_left", payload),
    do: handle_participant_left(payload)

  defp route_event(channel, _payload),
    do: Logger.warning("[CallsSubscriber] Unknown channel: #{channel}")

  @doc """
  Broadcasts `incoming_call` on the user channel for every participant other
  than the initiator. Exposed so tests can invoke the routing directly without
  a live Redis transport.
  """
  @spec broadcast_incoming_call(map()) :: :ok
  def broadcast_incoming_call(payload) do
    initiator_id = payload["initiator_id"]
    participant_ids = payload["participant_ids"] || []

    targets =
      participant_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(fn uid -> uid == "" or uid == initiator_id end)
      |> Enum.uniq()

    data = %{
      "call_id" => payload["call_id"],
      "initiator_id" => initiator_id,
      "conversation_id" => payload["conversation_id"],
      "type" => payload["type"],
      "started_at" => payload["started_at"]
    }

    for uid <- targets do
      WhisprMessagingWeb.Endpoint.broadcast("user:#{uid}", "incoming_call", data)
    end

    Logger.info(
      "[CallsSubscriber] Broadcast incoming_call to #{length(targets)} user(s) (call=#{payload["call_id"]})"
    )

    :ok
  end

  @doc """
  Handles a `participant_left` event from calls-service.

  Guards against two late-arrival scenarios that occur when the LiveKit webhook
  fires after the conversation has already been ended or removed:

  - conversation absente (nil) : log warn, retourne :ok — idempotent.
  - conversation inactive (is_active: false) : log info, retourne :ok — idempotent.
  - cas normal : broadcast `participant_left` sur le topic conversation:*.

  Exposed as a public function so tests can invoke it directly without a live
  Redis transport (meme pattern que `broadcast_incoming_call/1`).
  """
  @spec handle_participant_left(map()) :: :ok
  def handle_participant_left(payload) do
    conversation_id = payload["conversation_id"]
    user_id = payload["user_id"]
    call_id = payload["call_id"]

    case Repo.get(Conversation, conversation_id) do
      nil ->
        Logger.warning(
          "[CallsSubscriber] participant_left ignored: conversation not found",
          conversation_id: conversation_id,
          user_id: user_id,
          call_id: call_id
        )

        :ok

      %Conversation{is_active: false} ->
        Logger.info(
          "[CallsSubscriber] participant_left ignored: conversation inactive",
          conversation_id: conversation_id,
          user_id: user_id,
          call_id: call_id
        )

        :ok

      %Conversation{is_active: true} ->
        data = %{
          "call_id" => call_id,
          "conversation_id" => conversation_id,
          "user_id" => user_id,
          "left_at" => payload["left_at"]
        }

        WhisprMessagingWeb.Endpoint.broadcast(
          "conversation:#{conversation_id}",
          "participant_left",
          data
        )

        Logger.info(
          "[CallsSubscriber] Broadcast participant_left (call=#{call_id}, user=#{user_id})"
        )

        :ok
    end
  end
end
