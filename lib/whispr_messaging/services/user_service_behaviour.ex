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
end
