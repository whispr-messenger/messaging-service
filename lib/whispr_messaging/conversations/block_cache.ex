defmodule WhisprMessaging.Conversations.BlockCache do
  @moduledoc """
  WHISPR-1364: cache court-vie des relations de blocage entre membres
  d'une conversation.

  Probleme : sur chaque message envoye dans un groupe, on doit savoir
  quels couples (sender, destinataire) sont en relation de blocage pour
  filtrer le broadcast. Faire un appel HTTP user-service par destinataire
  par message saturerait le service en chat actif (groupe de 20 -> 19
  appels par message).

  Solution : `get_for_conversation/2` retourne une map
  `%{user_id => MapSet.t([blocked_user_id, ...])}` ou la cle est l'user
  destinataire et la valeur l'ensemble des users qu'il a bloques (ou qui
  l'ont bloque - relation symetrique cote user-service). On lit
  `check_user_blocked/2` pour chaque paire ordonnee non triviale, puis on
  cache 60s par conversation_id.

  TTL : 60s. Compromis perf vs fraicheur. Quand un user (un)block un
  contact, le filtrage broadcast suit avec au pire 60s de retard. Les
  blocages sont rares en absolu (event ponctuel) et l'effet de bord d'un
  retard est mineur (un message broadcaste pendant la fenetre est juste
  visible une fois). En contrepartie, en groupe de 5 membres avec 100
  messages/min on passe de 2000 appels HTTP/min a ~5 (un seul rebuild par
  minute par conversation).
  """

  alias WhisprMessaging.Services.UserService

  @cache_ttl_ms 60 * 1000
  @cache_table :whispr_messaging_block_cache

  @doc """
  Renvoie la map des blocages pour une conversation a partir de la liste
  des `member_ids`. Retourne `%{}` si la liste est vide ou si aucune
  paire n'est bloquee.

  Utilise un cache ETS keye par `conversation_id`. Sur miss, fait
  `n*(n-1)` appels `check_user_blocked` (un par paire ordonnee). Sur
  erreur transitoire user-service, on omet la paire (fail-open : on
  ne veut pas bloquer l'app messaging si user-service est down).
  """
  def get_for_conversation(conversation_id, member_ids) when is_list(member_ids) do
    ensure_table()

    case cache_get(conversation_id) do
      {:ok, blocks} ->
        blocks

      :miss ->
        blocks = build_blocks(member_ids)
        cache_put(conversation_id, blocks)
        blocks
    end
  end

  @doc """
  Invalide l'entree de cache pour une conversation. A appeler quand on
  apprend qu'un block a change (idealement via event Redis user-service,
  pas implemente pour l'instant - le TTL 60s sert de filet).
  """
  def invalidate(conversation_id) do
    ensure_table()
    :ets.delete(@cache_table, conversation_id)
    :ok
  end

  @doc false
  def reset do
    ensure_table()
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  # ---------------------------------------------------------------------------

  defp build_blocks(member_ids) do
    # Pour chaque destinataire potentiel, on construit l'ensemble des
    # autres membres qu'il a bloques (ou qui l'ont bloque). On itere
    # sur les paires ordonnees.
    Enum.reduce(member_ids, %{}, fn user_id, acc ->
      blocked_set =
        member_ids
        |> Enum.reject(&(&1 == user_id))
        |> Enum.reduce(MapSet.new(), fn other_id, set ->
          if blocked_pair?(user_id, other_id) do
            MapSet.put(set, other_id)
          else
            set
          end
        end)

      if MapSet.size(blocked_set) > 0 do
        Map.put(acc, user_id, blocked_set)
      else
        acc
      end
    end)
  end

  # Vrai si un block existe entre les deux users (peu importe le sens).
  # On fail-open sur erreur transitoire : on ne veut pas qu'une indispo
  # user-service noircisse soudainement le filtre et ressuscite des
  # blocages fantomes. Un block legitime sera revalu apres le TTL.
  defp blocked_pair?(user_a, user_b) do
    case UserService.check_user_blocked(user_a, user_b) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  defp cache_get(conversation_id) do
    case :ets.lookup(@cache_table, conversation_id) do
      [{^conversation_id, blocks, expires_at_ms}] ->
        if expires_at_ms > now_ms() do
          {:ok, blocks}
        else
          :ets.delete(@cache_table, conversation_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(conversation_id, blocks) do
    :ets.insert(@cache_table, {conversation_id, blocks, now_ms() + cache_ttl_ms()})
    :ok
  end

  defp cache_ttl_ms do
    config = Application.get_env(:whispr_messaging, :block_cache, [])
    Keyword.get(config, :ttl_ms, @cache_ttl_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
