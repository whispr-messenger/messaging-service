# Signalements

## Flux

```
User signale ──▶ POST /reports
                      │
                ┌─────▼─────┐
                │  Stockage  │
                │  du report │
                └─────┬─────┘
                      │
                ┌─────▼─────┐
                │  Admin     │
                │  review    │
                └─────┬─────┘
                 action │ classé
                ┌──────┼──────┐
                │             │
           Sanction      Fermé
```
