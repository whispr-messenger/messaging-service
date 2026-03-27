#!/bin/bash
set -e

cd /app

mix local.hex --force
mix local.rebar --force

MIX_ENV=dev mix ecto.migrate
exec env MIX_ENV=dev mix phx.server
