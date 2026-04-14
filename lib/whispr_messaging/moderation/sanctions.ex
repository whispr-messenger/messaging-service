defmodule WhisprMessaging.Moderation.Sanctions do
  @moduledoc """
  Context for managing conversation-level sanctions.

  Handles muting, kicking, and shadow-restricting users within conversations.
  Includes expiration handling for temporary sanctions.
  """

  alias WhisprMessaging.Repo
  alias WhisprMessaging.Moderation.ConversationSanction

  require Logger

  @doc """
  Creates a conversation sanction (mute, kick, or shadow_restrict).
  """
  def create_sanction(attrs) do
    %ConversationSanction{}
    |> ConversationSanction.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn sanction ->
      Logger.info(
        "Sanction #{sanction.type} applied to #{sanction.user_id} in conversation #{sanction.conversation_id}"
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
        Logger.info("Sanction #{lifted.id} lifted for user #{lifted.user_id}")
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
      Logger.info("Expired #{count} conversation sanctions")
    end

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Broadcasting (WebSocket)
  # ---------------------------------------------------------------------------

  defp broadcast_sanction_event(%{type: "mute"} = sanction) do
    WhisprMessagingWeb.Endpoint.broadcast(
      "conversation:#{sanction.conversation_id}",
      "moderation:user_muted",
      %{
        user_id: sanction.user_id,
        reason: sanction.reason,
        expires_at: sanction.expires_at && DateTime.to_iso8601(sanction.expires_at)
      }
    )
  end

  defp broadcast_sanction_event(%{type: "kick"} = sanction) do
    WhisprMessagingWeb.Endpoint.broadcast(
      "conversation:#{sanction.conversation_id}",
      "moderation:user_kicked",
      %{user_id: sanction.user_id, reason: sanction.reason}
    )
  end

  defp broadcast_sanction_event(_), do: :ok

  defp broadcast_sanction_lifted(sanction) do
    WhisprMessagingWeb.Endpoint.broadcast(
      "conversation:#{sanction.conversation_id}",
      "moderation:sanction_lifted",
      %{user_id: sanction.user_id, sanction_type: sanction.type}
    )
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

    Redix.command(:redix, ["PUBLISH", "whispr:moderation:sanction_applied", payload])
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(error, _fun), do: error
end
