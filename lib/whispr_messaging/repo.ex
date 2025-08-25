defmodule WhisprMessaging.Repo do
  use Ecto.Repo,
    otp_app: :whispr_messaging,
    adapter: Ecto.Adapters.Postgres
end
