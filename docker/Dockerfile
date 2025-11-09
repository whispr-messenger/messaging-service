# Dockerfile for WhisprMessaging Service
# Multi-stage build for production-ready Elixir/Phoenix application

# Build stage
FROM elixir:1.15-alpine AS build

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    erlang-dev

# Set environment variables
ENV MIX_ENV=prod

# Create app directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
COPY deps.get.sh ./
RUN chmod +x deps.get.sh && ./deps.get.sh || mix deps.get

# Copy source code
COPY . .

# Install node dependencies for assets (if any)
RUN if [ -f "assets/package.json" ]; then \
      cd assets && \
      npm ci --progress=false --no-audit --loglevel=error && \
      npm run deploy; \
    fi

# Compile application
RUN mix deps.compile
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM alpine:3.18 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    openssl \
    ncurses-libs \
    libstdc++

# Create app user
RUN addgroup -g 1000 app && \
    adduser -D -s /bin/bash -u 1000 -G app app

# Set work directory
WORKDIR /app

# Copy release from build stage
COPY --from=build --chown=app:app /app/_build/prod/rel/whispr_messaging ./

# Set environment
ENV MIX_ENV=prod
ENV PHX_HOST=0.0.0.0
ENV PHX_PORT=4000
ENV GRPC_PORT=50052

# Switch to app user
USER app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:${PHX_PORT}/health || exit 1

# Expose ports
EXPOSE 4000 50052

# Start the application
CMD ["./bin/whispr_messaging", "start"]