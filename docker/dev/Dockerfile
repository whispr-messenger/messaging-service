FROM elixir:1.19

WORKDIR /app

ENV MIX_ENV=dev

COPY ./docker/dev/requirements.txt .

RUN apt-get update && apt-get install -y --no-install-recommends $(cat requirements.txt) \
    && rm -rf /var/lib/apt/lists/*

<<<<<<< Updated upstream
# Install hex and rebar in the image so later mix commands can reuse them reliably
RUN mix local.hex --force && \
    mix local.rebar --force
=======
# Install hex and rebar
RUN --mount=type=cache,target=/root/.hex \
    mix local.hex --force && mix local.rebar --force
>>>>>>> Stashed changes

# Copy mix files first for better layer caching
COPY mix.exs mix.lock ./

<<<<<<< Updated upstream
RUN MIX_ENV=dev mix deps.get

=======
>>>>>>> Stashed changes
# Pre-compile dependencies so the container starts immediately without compilation delay
RUN --mount=type=cache,target=/root/.hex \
    mix do local.hex --force, local.rebar --force, deps.get, deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN --mount=type=cache,target=/root/.hex \
    mix compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN MIX_ENV=dev mix compile

COPY ./docker/dev/entrypoint.sh /tmp/entrypoint.sh
RUN chmod +x /tmp/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 CMD curl -f http://localhost:4000/metrics || exit 1

<<<<<<< Updated upstream
# Ajout d'un utilisateur non-root
RUN useradd -m appuser && chown -R appuser /app
USER appuser

=======
>>>>>>> Stashed changes
ENTRYPOINT [ "/usr/bin/tini", "--", "/bin/bash", "/tmp/entrypoint.sh" ]
