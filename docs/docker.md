# Docker

## Build

```bash
docker build -t messaging-service .
```

## Run local

Les fichiers docker-compose sont dans le dossier `docker/` :

```bash
# Dev
docker-compose -f docker/dev/docker-compose.yml up -d

# Prod
docker-compose -f docker/prod/docker-compose.yml up -d

# Test
docker-compose -f docker/test/docker-compose.yml up -d
```

## Dépendances

Le docker-compose démarre :
- PostgreSQL
- Redis
- Le service messaging
