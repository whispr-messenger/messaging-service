#!/bin/bash
set -e

cd /app

<<<<<<< Updated upstream
mix local.hex --force
mix local.rebar --force

MIX_ENV=dev mix ecto.migrate
exec env MIX_ENV=dev mix phx.server
=======
# Run database migrations
mix ecto.migrate

mix phx.server
>>>>>>> Stashed changes
