#!/bin/bash

# Only get deps if deps directory is empty or mix.lock changed
if [ ! -d "deps" ] || [ ! -f ".deps_installed" ] || [ "mix.lock" -nt ".deps_installed" ]; then
    mix deps.get
    touch .deps_installed
fi

# Run database migrations
mix ecto.migrate

mix phx.server