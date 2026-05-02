default:
    just --list

up ENV:
    #!/bin/bash
    if [ "{{ENV}}" = "dev" ]; then
        docker compose -f docker/dev/compose.yml up -d --build
    elif [ "{{ENV}}" = "prod" ]; then
        # Create common network if it doesn't exist
        if ! docker network inspect whispr-common-network >/dev/null 2>&1; then
            echo "Creating whispr-common-network..."
            docker network create whispr-common-network
        fi
        docker compose -f docker/prod/compose.yml up --detach --build
    elif [ "{{ENV}}" = "doc" ]; then
        docker compose -f docker/doc/compose.yml up --detach
    elif [ "{{ENV}}" = "test" ]; then
        docker compose -f docker/test/compose.yml up --abort-on-container-exit --build
    else
        echo "{{ENV}}: Accepted values are 'dev', 'prod', 'doc' or 'test'." >&2
    fi

down ENV:
    #!/bin/bash
    if [ "{{ENV}}" = "dev" ]; then
        docker compose -f docker/dev/compose.yml down --volumes
    elif [ "{{ENV}}" = "prod" ]; then
        docker compose -f docker/prod/compose.yml down --volumes
        # Remove common network if it exists and has no more containers
        if docker network inspect whispr-common-network >/dev/null 2>&1; then
            containers=$(docker ps -q --filter "network=whispr-common-network" 2>/dev/null | xargs)
            if [ -z "$containers" ]; then
                echo "Removing unused whispr-common-network..."
                docker network rm whispr-common-network 2>/dev/null || true
            else
                echo "whispr-common-network still in use by containers: $containers"
            fi
        fi
    elif [ "{{ENV}}" = "doc" ]; then
        docker compose -f docker/doc/compose.yml down --volumes
    elif [ "{{ENV}}" = "test" ]; then
        docker compose -f docker/test/compose.yml down
    else
        echo "{{ENV}}: Accepted values are 'dev', 'prod', 'doc' or 'test'." >&2
    fi

logs ENV:
    #!/bin/bash
    if [ "{{ENV}}" = "dev" ]; then
        docker compose -f docker/{{ENV}}/compose.yml logs --follow
    elif [ "{{ENV}}" = "prod" ]; then
        docker compose -f docker/{{ENV}}/compose.yml logs --follow
    else
        echo "{{ENV}}: Accepted values are 'dev' or 'prod'." >&2
    fi


shell:
    docker compose -f docker/dev/compose.yml exec -it messaging-service bash

test:
    docker compose -f docker/test/compose.yml up --abort-on-container-exit --exit-code-from test-runner --build

# Fast iteration loop: starts postgres/redis if needed, then runs `mix test`
# in a one-shot test-runner container without the coverage pipeline (which
# requires the host `cover/` directory to be writable by the container user
# and is overkill when iterating). An optional argument is forwarded to
# `mix test`, e.g. `just test-fast test/whispr_messaging/conversations_test.exs:186`.
test-fast ARGS="":
    #!/bin/bash
    set -euo pipefail
    docker compose -f docker/test/compose.yml up -d postgres redis
    docker compose -f docker/test/compose.yml run --rm -e MIX_ENV=test test-runner \
        /bin/bash -c "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && mix deps.get --only test && mix ecto.create --quiet && mix ecto.migrate --quiet && mix test {{ARGS}}"

# Install git hooks manually (alternative to the automatic busybox container).
# Useful for contributors who don't use the Docker dev stack.
setup-hooks:
    #!/bin/bash
    set -euo pipefail
    if [ ! -d ".githooks" ]; then
        echo "Error: .githooks/ directory not found." >&2
        exit 1
    fi
    # Use sudo if the existing hook files are owned by another user (e.g. root
    # from a previous busybox container run).
    _cp() {
        if [ -f "$2" ] && [ ! -w "$2" ]; then
            sudo cp "$1" "$2" && sudo chown "$(id -u):$(id -g)" "$2"
        else
            cp "$1" "$2"
        fi
    }
    _cp .githooks/pre-commit .git/hooks/pre-commit
    _cp .githooks/pre-push   .git/hooks/pre-push
    chmod +x .git/hooks/pre-commit .git/hooks/pre-push
    echo "Git hooks installed successfully."