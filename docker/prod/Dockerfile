# =============================================================================
# Whispr Messaging Service - Dockerfile
# Multi-stage build for production-ready Elixir/Phoenix application
# =============================================================================

# -----------------------------------------------------------------------------
# STAGE 1: Build
# -----------------------------------------------------------------------------
FROM elixir:1.19-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    curl

# Set environment variables
ENV MIX_ENV=prod \
    LANG=C.UTF-8

# Create app directory
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first (for caching)
COPY mix.exs mix.lock ./
COPY config config

# Install dependencies with BuildKit cache mounts
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.get --only prod && \
    mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv

# Compile the application
RUN mix compile

# Build release
RUN mix release

# -----------------------------------------------------------------------------
# STAGE 2: Runtime
# -----------------------------------------------------------------------------
FROM alpine:3.18 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc \
    curl \
    bash

# Create non-root user for security
RUN addgroup -g 1000 whispr && \
    adduser -u 1000 -G whispr -s /bin/sh -D whispr

# Set environment variables
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    PORT=4000 \
    GRPC_PORT=4001

# Create app directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=whispr:whispr /app/_build/prod/rel/whispr_messaging ./

# Switch to non-root user
USER whispr

# Expose ports (HTTP + gRPC)
EXPOSE 4000 4001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:4000/api/v1/health?type=live || exit 1

# OCI Labels
LABEL org.opencontainers.image.title="Whispr Messaging Service" \
      org.opencontainers.image.description="Real-time messaging service for Whispr Messenger" \
      org.opencontainers.image.vendor="Whispr" \
      org.opencontainers.image.version="1.0.0"

# Start the application
CMD ["bin/whispr_messaging", "start"]