#!/bin/bash
# Dependency installation script for WhisprMessaging service
# This script handles dependency installation with proper error handling

set -e

echo "Installing Elixir dependencies for WhisprMessaging..."

# Ensure we have the latest hex and rebar
mix local.hex --force
mix local.rebar --force

# Clean any previous builds in production
if [ "$MIX_ENV" = "prod" ]; then
    echo "Production build detected, cleaning previous builds..."
    mix deps.clean --all
    mix clean
fi

# Get dependencies
echo "Fetching dependencies..."
mix deps.get

# Compile dependencies
echo "Compiling dependencies..."
mix deps.compile

echo "Dependencies installed successfully!"

# Show dependency status
echo "Dependency status:"
mix deps