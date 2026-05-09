defmodule WhisprMessaging.Invites do
  @moduledoc """
  Group conversation invite-link management (WHISPR-1046).

  Exposes functions to generate, revoke and consume invite tokens used to join
  a group conversation via a shareable URL of the form `whispr://invite/<token>`.
  """

  import Ecto.Query, warn: false

  alias WhisprMessaging.Conversations
  alias WhisprMessaging.Conversations.{Conversation, ConversationMember}
  alias WhisprMessaging.Repo

  # Default TTL: 7 days.
  @default_ttl_seconds 7 * 24 * 3600

  # Plafond de membres actifs par groupe (anti-flood via invite link).
  @max_group_members 256

  @doc """
  Generates a new invite token for a group conversation.

  Only callable by an active admin of the conversation. Returns the updated
  conversation with fresh `invite_token` and `invite_expires_at`.
  """
  def generate_invite(conversation_id, actor_user_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, conversation} <- Conversations.get_conversation(conversation_id),
         :ok <- ensure_group(conversation),
         :ok <- ensure_admin(conversation_id, actor_user_id) do
      attrs = %{
        invite_token: Ecto.UUID.generate(),
        invite_expires_at: expires_at(ttl)
      }

      conversation
      |> Conversation.invite_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Revokes the current invite token, if any.
  """
  def revoke_invite(conversation_id, actor_user_id) do
    with {:ok, conversation} <- Conversations.get_conversation(conversation_id),
         :ok <- ensure_group(conversation),
         :ok <- ensure_admin(conversation_id, actor_user_id) do
      conversation
      |> Conversation.invite_changeset(%{invite_token: nil, invite_expires_at: nil})
      |> Repo.update()
    end
  end

  @doc """
  Joins the authenticated user to a conversation referenced by an invite token.

  Returns `{:ok, %{conversation: c, member: m, already_member: boolean}}` on
  success. Erreurs possibles :
    * `{:error, :not_found}` — token inconnu, révoqué, ou expiré
    * `{:error, :previously_kicked}` — l'utilisateur a déjà été kické du groupe ;
      un re-invite explicite par un admin est requis (pas de réactivation silencieuse)
    * `{:error, :member_cap_reached}` — le groupe a atteint le plafond `@max_group_members`
  """
  def join_by_token(token, user_id) when is_binary(token) and is_binary(user_id) do
    Repo.transaction(fn ->
      with {:ok, conversation} <- fetch_by_token(token),
           :ok <- ensure_not_expired(conversation),
           {:ok, result} <- do_join(conversation, user_id) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp do_join(conversation, user_id) do
    case Conversations.get_conversation_member(conversation.id, user_id) do
      %ConversationMember{is_active: true} = member ->
        {:ok, %{conversation: conversation, member: member, already_member: true}}

      # un kické ne peut pas se re-inviter via le lien : il faut un re-invite admin explicite
      %ConversationMember{is_active: false} ->
        {:error, :previously_kicked}

      nil ->
        with :ok <- ensure_under_member_cap(conversation.id),
             {:ok, member} <- Conversations.add_conversation_member(conversation.id, user_id) do
          {:ok, %{conversation: conversation, member: member, already_member: false}}
        end
    end
  end

  defp ensure_under_member_cap(conversation_id) do
    if Conversations.count_conversation_members(conversation_id) >= @max_group_members do
      {:error, :member_cap_reached}
    else
      :ok
    end
  end

  @doc """
  Builds the shareable invite URL for a token.
  """
  def invite_url(token) when is_binary(token), do: "whispr://invite/#{token}"

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp fetch_by_token(token) do
    case Repo.one(from c in Conversation, where: c.invite_token == ^token and c.is_active == true) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp ensure_not_expired(%Conversation{invite_expires_at: nil}), do: {:error, :not_found}

  defp ensure_not_expired(%Conversation{invite_expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp ensure_group(%Conversation{type: "group"}), do: :ok
  defp ensure_group(_), do: {:error, :not_a_group}

  defp ensure_admin(conversation_id, user_id) do
    case Conversations.get_conversation_member(conversation_id, user_id) do
      %ConversationMember{is_active: true} = member ->
        if Conversations.member_role(member) == "admin" do
          :ok
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  defp expires_at(ttl_seconds) do
    DateTime.utc_now()
    |> DateTime.add(ttl_seconds, :second)
    |> DateTime.truncate(:second)
  end
end
