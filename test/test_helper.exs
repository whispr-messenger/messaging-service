ExUnit.start()

# Configure Ecto sandbox for concurrent tests
Ecto.Adapters.SQL.Sandbox.mode(WhisprMessaging.Repo, :manual)
