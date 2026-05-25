defmodule WhisprMessaging.Services.UserServiceBehaviour do
  @moduledoc """
  Contrat des clients user-service consommes par messaging-service.

  Les implementations doivent parler a user-service via l'API HTTP
  interne (`/internal/v1/...`) authentifiee par le secret partage
  `x-internal-token`, conformement au contrat introduit dans
  WHISPR-1230.
  """

  @doc """
  Renvoie `{:ok, true}` quand l'utilisateur semble exister cote
  user-service.

  Aujourd'hui c'est surtout un proxy de la dispo de user-service : pas
  d'endpoint d'existence dedie, du coup les implementations passent par
  un appel self-paire a `/contacts/check`. Voir
  `WhisprMessaging.Services.HttpUserServiceClient` pour le pourquoi et
  le ticket de suivi.
  """
  @callback check_user_exists(user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Renvoie `{:ok, true}` quand `blocker_id` a bloque `blocked_id` (ou
  l'inverse, selon la semantique bidirectionnelle de l'implementation),
  `{:ok, false}` sinon.

  En cas d'echec transitoire l'implementation doit fail-closed
  (considerer comme bloque) en renvoyant `{:error, _}` afin que les
  appelants refusent l'action par defaut.
  """
  @callback check_user_blocked(blocker_id :: String.t(), blocked_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Renvoie les flags de privacy settings du user (`read_receipts`,
  `last_seen_privacy`, etc.) en allant chercher
  `GET /internal/users/:id/privacy` cote user-service.

  Politique fail-safe : sur `{:error, _}` les appelants doivent
  fallback en mode "broadcast autorise" (fail-open) plutot que de
  casser un scenario nominal. Le gating WhatsApp punitive est une
  regle de privacy, pas une regle de securite, donc une indispo de
  user-service ne doit pas couper les read receipts par defaut.
  """
  @callback get_privacy_settings(user_id :: String.t()) ::
              {:ok, %{required(:read_receipts) => boolean(), optional(atom()) => any()}}
              | {:error, term()}

  @doc """
  Renvoie le nom d'affichage d'un utilisateur ("Prenom Nom" ou username)
  via `GET /internal/users/:id/display-name` cote user-service.

  Politique fail-open : en cas d'erreur les appelants doivent fallback
  sur `nil` et ne pas bloquer la livraison du message.
  """
  @callback get_display_name(user_id :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
end
