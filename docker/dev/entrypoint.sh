#!/bin/bash
set -e

cd /app

mix local.hex --force
mix local.rebar --force

mix deps.get
mix deps.compile --skip-umbrella-children

MIX_ENV=dev mix ecto.migrate
exec env MIX_ENV=dev mix phx.server
