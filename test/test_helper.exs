ExUnit.start()

# Configure Ecto sandbox for concurrent tests
Ecto.Adapters.SQL.Sandbox.mode(WhisprMessaging.Repo, :manual)

# Default to a no-op new_message dispatcher so tests that create messages
# don't leak DB-touching tasks outliving the sandbox. Tests that want to
# observe the publish can override this via Application.put_env.
Application.put_env(:whispr_messaging, :new_message_dispatcher, fn _ -> :ok end)

# Same no-op for inbox events — Tasks spawned by the default dispatcher would
# try to use the Ecto sandbox from a different process and panic.
# Tests that want to observe inbox publishes override this in their setup.
Application.put_env(:whispr_messaging, :inbox_events_dispatcher, fn _ -> :ok end)
