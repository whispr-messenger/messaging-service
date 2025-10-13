# Development Dockerfile for Whispr Messaging Service
FROM elixir:1.15-alpine

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    inotify-tools \
    postgresql-client \
    curl

# Set working directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set environment
ENV MIX_ENV=dev

# Expose ports
EXPOSE 4000 50052

# Default command
CMD ["mix", "phx.server"]
