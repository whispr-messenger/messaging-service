defmodule WhisprMessaging.Services.UserServiceBehaviour do
  @moduledoc """
  Contract for user-service clients consumed by the messaging-service.

  Implementations must talk to user-service over the internal HTTP API
  (`/internal/v1/...`) authenticated by the `x-internal-token` shared secret,
  matching the contract introduced in WHISPR-1230.
  """

  @doc """
  Returns `{:ok, true}` when the user appears to exist on user-service.

  Today this is a proxy of user-service availability — there is no dedicated
  existence endpoint, so implementations rely on a self-paired call to
  `/contacts/check`. See `WhisprMessaging.Services.HttpUserServiceClient` for
  the rationale and the follow-up ticket linked there.
  """
  @callback check_user_exists(user_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Returns `{:ok, true}` when `blocker_id` has blocked `blocked_id` (or vice
  versa, depending on the implementation's bidirectional semantics), `{:ok,
  false}` otherwise.

  On transient failure the implementation must fail-closed (assume blocked) by
  returning `{:error, _}` so callers can deny the action by default.
  """
  @callback check_user_blocked(blocker_id :: String.t(), blocked_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}
end
