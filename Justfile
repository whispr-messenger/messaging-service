# justfile for WhisprMessaging Service

# Default recipe to show available commands
default:
    @just --list

# Start the development environment
up:
    docker compose -f docker/docker-compose.dev.yml up -d

# Stop the development environment
down:
    docker compose -f docker/docker-compose.dev.yml down

# Stop and remove volumes (full cleanup)
down-volumes:
    docker compose -f docker/docker-compose.dev.yml down -v

# View logs from all services
logs:
    docker compose -f docker/docker-compose.dev.yml logs -f

# View logs from a specific service
logs-service service:
    docker compose -f docker/docker-compose.dev.yml logs -f {{service}}

# Restart all services
restart:
    docker compose -f docker/docker-compose.dev.yml restart

# Restart a specific service
restart-service service:
    docker compose -f docker/docker-compose.dev.yml restart {{service}}

# Show status of all services
ps:
    docker compose -f docker/docker-compose.dev.yml ps

# Open a shell in the messaging service container
shell:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service sh

# Run mix commands in the messaging service container
mix *args:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix {{args}}

# Run database migrations
migrate:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix ecto.migrate

# Rollback database migration
rollback:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix ecto.rollback

# Run tests
test:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix test

# Format code
format:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix format

# Check code formatting
format-check:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix format --check-formatted

# Run Credo
credo:
    docker compose -f docker/docker-compose.dev.yml exec messaging-service mix credo

# Rebuild and restart services
rebuild:
    docker compose -f docker/docker-compose.dev.yml up -d --build

# Pull latest images
pull:
    docker compose -f docker/docker-compose.dev.yml pull
