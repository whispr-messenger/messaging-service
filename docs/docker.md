# Docker

## Build

```bash
docker build -t messaging-service .
```

## Run local

```bash
docker-compose up -d
```

## Dépendances

Le docker-compose démarre :
- PostgreSQL
- Redis
- Le service messaging
