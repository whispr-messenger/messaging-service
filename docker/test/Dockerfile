FROM elixir:1.19

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install hex and rebar with cache
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix local.hex --force && \
    mix local.rebar --force

# Copy mix files first for better layer caching
COPY mix.exs mix.lock ./

# Get dependencies with cache
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.get --only test

# Set test environment
ENV MIX_ENV=test

# Create non-root user for running tests.
# Note: we keep root as the runtime user because bind-mounted volumes
# (cover/, app source) may be owned by root and the UID mismatch would
# cause permission errors writing coverage reports.
RUN useradd -m -u 1000 appuser && chown -R appuser /app
