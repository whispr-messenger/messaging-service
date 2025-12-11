#!/bin/bash

mix deps.get

# Run database migrations
mix ecto.migrate

mix phx.server