default:
    just --list

up ENV:
    #!/bin/bash
    if [ "{{ENV}}" = "dev" ]; then
        docker compose -f docker/dev/compose.yml up -d --build
    elif [ "{{ENV}}" = "prod" ]; then
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
    elif [ "{{ENV}}" = "doc" ]; then
        docker compose -f docker/doc/compose.yml down --volumes
    elif [ "{{ENV}}" = "test" ]; then
        docker compose -f docker/test/compose.yml down --volumes
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