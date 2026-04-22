# Déploiement

## Flux

```
mix release ──▶ Docker build ──▶ GHCR ──▶ ArgoCD ──▶ K8s
```

## Commandes

```bash
# Build release
MIX_ENV=prod mix release

# Build Docker
docker build -t messaging-service .
```

## Health probes K8s

```
GET /live   — Liveness probe
GET /ready  — Readiness probe
GET /messaging/api/v1/health — Health check détaillé
```
