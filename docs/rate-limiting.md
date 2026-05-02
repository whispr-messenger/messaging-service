# Rate Limiting

## Configuration

Le rate limiter est implémenté via un plug Phoenix.

```
Requête ──▶ RateLimiter Plug ──▶ Compteur Redis
                                      │
                                Limit atteint?
                                 non │ oui
                                ┌────┼────┐
                                │        │
                           Continuer   429
```

## Limites

Les limites sont configurables par endpoint.
