defmodule WhisprMessaging.Services.MockUserServiceClient do
  @moduledoc """
  Test-only implementation of `WhisprMessaging.Services.UserServiceBehaviour`.

  By default the mock returns "user exists, not blocked" so the legacy test
  suite (which never set up explicit user-service stubs) keeps passing.

  Tests that need to assert specific behaviours can override the default by
  storing a function under the test process's `:mock_user_service_client` key:

      Process.put(:mock_user_service_client, %{
        check_user_exists: fn _id -> {:ok, false} end,
        check_user_blocked: fn _b, _t -> {:ok, true} end
      })

  The dispatcher does not look at this directly; it calls the configured module
  (this one) which then reads the per-process overrides.
  """

  @behaviour WhisprMessaging.Services.UserServiceBehaviour

  @impl true
  def check_user_exists(user_id) do
    case overrides()[:check_user_exists] do
      fun when is_function(fun, 1) -> fun.(user_id)
      _ -> {:ok, true}
    end
  end

  @impl true
  def check_user_blocked(blocker_id, blocked_id) do
    case overrides()[:check_user_blocked] do
      fun when is_function(fun, 2) -> fun.(blocker_id, blocked_id)
      _ -> {:ok, false}
    end
  end

  defp overrides do
    Process.get(:mock_user_service_client) || %{}
  end
end
