#!/bin/bash

# Install Hex and Rebar (needed because volume mount may override them)
mix local.hex --force
mix local.rebar --force

# Only get deps if deps directory is empty or mix.lock changed
if [ ! -d "deps" ] || [ ! -f ".deps_installed" ] || [ "mix.lock" -nt ".deps_installed" ]; then
    mix deps.get
    touch .deps_installed
fi

# Run database migrations
mix ecto.migrate

mix phx.server