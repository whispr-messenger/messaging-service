# Déploiement

## Flux

```
mix release ──▶ Docker build ──▶ GHCR ──▶ ArgoCD ──▶ GKE
```

## Commandes

```bash
# Build release
MIX_ENV=prod mix release

# Build Docker
docker build -t messaging-service .
```

## Healthcheck

Le pod expose `/health` pour les probes K8s.
