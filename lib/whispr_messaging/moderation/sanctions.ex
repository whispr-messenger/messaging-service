defmodule WhisprMessaging.Moderation.Sanctions do
  @moduledoc """
  Context for managing conversation-level sanctions.

  Handles muting, kicking, and shadow-restricting users within conversations.
  Includes expiration handling for temporary sanctions.
  """

  import WhisprMessaging.Moderation.Helpers, only: [tap_ok: 2, redis_publish: 2]

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Moderation.ConversationSanction
  alias WhisprMessaging.Repo

  require Logger

  @doc """
  Creates a conversation sanction (mute, kick, or shadow_restrict).
  """
  def create_sanction(attrs) do
    %ConversationSanction{}
    |> ConversationSanction.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn sanction ->
      Logger.info("Sanction applied",
        sanction_type: sanction.type,
        user_id: sanction.user_id,
        conversation_id: sanction.conversation_id,
        domain: :moderation
      )

      broadcast_sanction_event(sanction)
      publish_sanction_applied(sanction)
    end)
  end

  @doc """
  Lists active sanctions for a conversation.
  """
  def list_active_sanctions(conversation_id) do
    ConversationSanction
    |> ConversationSanction.active_for_conversation(conversation_id)
    |> Repo.all()
  end

  @doc """
  Gets a sanction by ID.
  """
  def get_sanction(id) do
    case Repo.get(ConversationSanction, id) do
      nil -> {:error, :not_found}
      sanction -> {:ok, sanction}
    end
  end

  @doc """
  Lifts (deactivates) a sanction.
  """
  def lift_sanction(sanction_id) do
    with {:ok, sanction} <- get_sanction(sanction_id),
         true <- sanction.active || {:error, :already_lifted} do
      sanction
      |> ConversationSanction.lift_changeset()
      |> Repo.update()
      |> tap_ok(fn lifted ->
        Logger.info("Sanction lifted",
          sanction_id: lifted.id,
          user_id: lifted.user_id,
          domain: :moderation
        )

        broadcast_sanction_lifted(lifted)
      end)
    end
  end

  @doc """
  Checks if a user is currently sanctioned (muted/shadow_restricted) in a conversation.
  Returns the active sanction or nil.
  """
  def active_sanction_for(conversation_id, user_id) do
    ConversationSanction
    |> ConversationSanction.active_for_user_in_conversation(conversation_id, user_id)
    |> Repo.one()
  end

  @doc """
  Deactivates all expired sanctions. Called by a periodic worker.
  """
  def expire_sanctions do
    {count, _} =
      ConversationSanction
      |> ConversationSanction.expired()
      |> Repo.update_all(set: [active: false])

    if count > 0 do
      Logger.info("Conversation sanctions expired", count: count, domain: :moderation)
    end

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Broadcasting (WebSocket)
  # ---------------------------------------------------------------------------

  defp broadcast_sanction_event(%{type: "mute"} = sanction) do
    payload = %{
      conversation_id: sanction.conversation_id,
      user_id: sanction.user_id,
      reason: sanction.reason,
      expires_at: sanction.expires_at && DateTime.to_iso8601(sanction.expires_at)
    }

    fanout_to_members(sanction.conversation_id, "moderation:user_muted", payload)
  end

  defp broadcast_sanction_event(%{type: "kick"} = sanction) do
    payload = %{
      conversation_id: sanction.conversation_id,
      user_id: sanction.user_id,
      reason: sanction.reason
    }

    fanout_to_members(sanction.conversation_id, "moderation:user_kicked", payload)
  end

  defp broadcast_sanction_event(_), do: :ok

  defp broadcast_sanction_lifted(sanction) do
    payload = %{
      conversation_id: sanction.conversation_id,
      user_id: sanction.user_id,
      sanction_type: sanction.type
    }

    fanout_to_members(sanction.conversation_id, "moderation:sanction_lifted", payload)
  end

  # Diffuse l event sur le topic conversation:* (pour les ChatScreen ouvertes)
  # ET sur le topic user:* de chaque membre pour que ConversationsListScreen
  # reflete le mute/kick/lift meme quand la ChatScreen n est pas ouverte.
  # Le user cible (mute/kick) recoit aussi l event sur son propre user:*
  # pour mettre a jour sa vue immediatement (meme pattern que message_deleted -
  # WHISPR-1293/1301). Si l appel DB echoue, on ne casse pas le flux principal.
  defp fanout_to_members(conversation_id, event, payload) do
    WhisprMessagingWeb.Endpoint.broadcast(
      "conversation:#{conversation_id}",
      event,
      payload
    )

    conversation_id
    |> Conversations.list_conversation_members()
    |> Enum.each(fn member ->
      WhisprMessagingWeb.Endpoint.broadcast("user:#{member.user_id}", event, payload)
    end)
  end

  # ---------------------------------------------------------------------------
  # Redis pub/sub
  # ---------------------------------------------------------------------------

  defp publish_sanction_applied(sanction) do
    payload =
      Jason.encode!(%{
        event: "sanction_applied",
        user_id: sanction.user_id,
        sanction_type: sanction.type,
        conversation_id: sanction.conversation_id,
        reason: sanction.reason,
        issued_by: sanction.issued_by,
        expires_at: sanction.expires_at && DateTime.to_iso8601(sanction.expires_at)
      })

    redis_publish("whispr:moderation:sanction_applied", payload)
  end
end
