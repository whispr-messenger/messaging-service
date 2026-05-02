defmodule WhisprMessaging.Workers.ModerationSubscriber do
  @moduledoc """
  Redis pub/sub subscriber for moderation decision events that must reach the
  end user over the Phoenix WebSocket.

  Subscribes to:
    * `whispr:moderation:blocked_image_approved`
    * `whispr:moderation:blocked_image_rejected`

  Rebroadcasts each decision on the `user:<user_id>` channel hosted by this
  service's Endpoint as the `blocked_image_decision` event, so the mobile
  client can auto-resend or annotate the contested image in real time.

  Lives in messaging-service (not notification-service) because this is the
  service that actually runs a Phoenix.Endpoint with `channel "user:*"`.
  """

  use GenServer
  require Logger

  @channels [
    "whispr:moderation:blocked_image_approved",
    "whispr:moderation:blocked_image_rejected"
  ]

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

        Logger.info(
          "[ModerationSubscriber] Subscribed to #{length(@channels)} moderation channels"
        )

        {:ok, %{pubsub: pubsub}}

      {:error, reason} ->
        Logger.error("[ModerationSubscriber] Failed to connect to Redis: #{inspect(reason)}")
        Process.send_after(self(), :retry_connect, 5_000)
        {:ok, %{pubsub: nil}}
    end
  end

  @impl true
  def handle_info(
        {:redix_pubsub, _pubsub, _ref, :subscribed, %{channel: channel}},
        state
      ) do
    Logger.debug("[ModerationSubscriber] Subscribed to #{channel}")
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
    Logger.info("[ModerationSubscriber] Retrying Redis connection...")
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
          "[ModerationSubscriber] Failed to decode payload on #{channel}: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.error("[ModerationSubscriber] Error handling #{channel}: #{inspect(error)}")
  end

  defp route_event("whispr:moderation:blocked_image_approved", payload),
    do: broadcast_decision("approved", payload)

  defp route_event("whispr:moderation:blocked_image_rejected", payload),
    do: broadcast_decision("rejected", payload)

  defp route_event(channel, _payload),
    do: Logger.warning("[ModerationSubscriber] Unknown channel: #{channel}")

  @doc """
  Broadcasts a moderation decision to the user's Phoenix channel.

  Exposed for testing and for direct calls that bypass the Redis transport.
  """
  @spec broadcast_decision(String.t(), map()) :: :ok
  def broadcast_decision(decision, payload) do
    user_id = payload["userId"]

    if is_binary(user_id) and user_id != "" do
      data =
        %{
          "appealId" => payload["appealId"],
          "decision" => decision,
          "messageTempId" => payload["messageTempId"],
          "conversationId" => payload["conversationId"],
          "reviewerNotes" => payload["reviewerNotes"]
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      WhisprMessagingWeb.Endpoint.broadcast(
        "user:#{user_id}",
        "blocked_image_decision",
        data
      )

      Logger.info(
        "[ModerationSubscriber] Broadcast #{decision} to user:#{user_id} (appeal=#{payload["appealId"]})"
      )

      :ok
    else
      Logger.warning(
        "[ModerationSubscriber] Missing userId on #{decision} payload (appeal=#{payload["appealId"]})"
      )

      :ok
    end
  end
end
