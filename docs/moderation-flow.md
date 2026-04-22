# Flux de modération

## Schéma

```
Message envoyé
     │
     ▼
┌────────────┐     ┌──────────────┐
│  Queue de  │────▶│  Moderation  │
│ modération │     │  Service     │
└────────────┘     └──────┬───────┘
                          │
                    ┌─────▼─────┐
                    │ Résultat  │
                    └─────┬─────┘
                     safe │ unsafe
                    ┌─────┼──────┐
                    │            │
              Distribué     Signalé
              aux users     + sanction
```

Les messages contenant des médias sont envoyés au moderation-service via une queue asynchrone.
