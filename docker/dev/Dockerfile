FROM elixir:1.19

WORKDIR /app

ENV HEX_HTTP_TIMEOUT=120
ENV HEX_HTTP_CONCURRENCY=1
ENV HEX_HTTP_RETRIES=20

COPY ./docker/dev/requirements.txt .

RUN (test -f /etc/apt/sources.list.d/debian.sources && sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources || true) \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=10 -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60 update \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=10 -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60 install -y --fix-missing --no-install-recommends $(cat requirements.txt) \
    && rm -rf /var/lib/apt/lists/*

# Install hex and rebar in the image so later mix commands can reuse them reliably
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files first for better layer caching
COPY mix.exs mix.lock ./

RUN MIX_ENV=dev mix deps.get

# Pre-compile dependencies so the container starts immediately without compilation delay
RUN MIX_ENV=dev mix deps.compile

COPY config ./config
COPY lib ./lib
COPY priv ./priv

RUN MIX_ENV=dev mix compile

COPY ./docker/dev/entrypoint.sh /tmp/entrypoint.sh
RUN chmod +x /tmp/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 CMD curl -fsS 'http://localhost:4000/api/v1/health?type=ready' || exit 1

# Ajout d'un utilisateur non-root
RUN useradd -m appuser && chown -R appuser /app
USER appuser

ENTRYPOINT [ "/usr/bin/tini", "--", "/bin/bash", "/tmp/entrypoint.sh" ]
