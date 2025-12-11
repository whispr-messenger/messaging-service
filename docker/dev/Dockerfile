FROM elixir:1.19

WORKDIR /app

COPY ./docker/dev/requirements.txt .

RUN apt-get update && apt-get install -y $(cat requirements.txt) \
    && rm -rf /var/lib/apt/lists/*

COPY ./docker/dev/entrypoint.sh /tmp/entrypoint.sh
RUN chmod +x /tmp/entrypoint.sh

ENTRYPOINT [ "/usr/bin/tini", "--", "/bin/bash", "/tmp/entrypoint.sh" ]