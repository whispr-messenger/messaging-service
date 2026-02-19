# =============================================================================
# Whispr Messaging Service - Dockerfile
# Multi-stage build for production-ready Elixir/Phoenix application
# =============================================================================

# -----------------------------------------------------------------------------
# STAGE 1: Build
# -----------------------------------------------------------------------------
# Pin to exact hexpm tag (OTP 28.2 + Alpine 3.23.3 = OpenSSL 3.3.x)
# Avoids floating tag drift that caused EVP_PKEY_sign_message_init crash in prod
FROM hexpm/elixir:1.19.5-erlang-28.2-alpine-3.23.3 AS builder

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
# Must match Alpine version of builder to ensure same OpenSSL (3.3.x)
FROM alpine:3.23 AS runtime

# Install runtime dependencies
# openssl on Alpine 3.23 = OpenSSL 3.3.x, which provides EVP_PKEY_sign_message_init
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    libgcc \
    curl \
    bash \
    tini

# Create non-root user for security
RUN addgroup -g 1000 whispr && \
    adduser -u 1000 -G whispr -s /bin/sh -D whispr

# Set environment variables (defaults, can be overridden)
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    HTTP_PORT=4000 \
    GRPC_PORT=4001 \
    PHX_HOST=0.0.0.0 \
    PHX_PORT=3999 \
    LOG_LEVEL=info

# Create app directory
WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=whispr:whispr /app/_build/prod/rel/whispr_messaging ./

# Copy entrypoint scripts
COPY --chown=whispr:whispr ./docker/prod/scripts/entrypoint.sh /app/entrypoint.sh
COPY --chown=whispr:whispr ./docker/prod/scripts/check-env.sh /app/check-env.sh

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/check-env.sh

# Switch to non-root user
USER whispr

# Expose ports (HTTP + gRPC)
EXPOSE 4000 4001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${HTTP_PORT:-4000}/api/v1/health?type=live || exit 1

# OCI Labels
LABEL org.opencontainers.image.title="Whispr Messaging Service" \
      org.opencontainers.image.description="Real-time messaging service for Whispr Messenger" \
      org.opencontainers.image.vendor="Whispr" \
      org.opencontainers.image.version="1.0.0"

# Use entrypoint with tini for proper signal handling
ENTRYPOINT ["/sbin/tini", "--", "/bin/bash", "/app/entrypoint.sh"]