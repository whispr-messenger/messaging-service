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

  @impl true
  def get_privacy_settings(user_id) do
    case overrides()[:get_privacy_settings] do
      fun when is_function(fun, 1) ->
        fun.(user_id)

      _ ->
        # Defaut nominal: read_receipts active. Le gating WHISPR-1304
        # broadcast donc normalement, comme l'ancien comportement
        # avant le ticket.
        {:ok,
         %{
           read_receipts: true,
           last_seen_privacy: nil,
           online_status: nil
         }}
    end
  end

  defp overrides do
    # 1. Process dict (test invocation directe).
    # 2. Walk up `$callers` (Task.Supervisor.start_child propagate
    #    `$callers` -> on retombe sur le test pid quand l'appel vient
    #    d'un Task spawn par la test process).
    # 3. Application env (test global, utilise quand un GenServer
    #    long-running comme ConversationServer fait l'appel : le pid
    #    n'a pas le test dans son `$callers`).
    case Process.get(:mock_user_service_client) do
      nil ->
        case overrides_from_callers() do
          map when map_size(map) > 0 -> map
          _ -> Application.get_env(:whispr_messaging, :mock_user_service_client_overrides, %{})
        end

      map ->
        map
    end
  end

  defp overrides_from_callers do
    callers = Process.get(:"$callers", [])

    Enum.find_value(callers, %{}, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, :mock_user_service_client)
        _ -> nil
      end
    end)
  end
end
