# Messages programmés

## Flux

```
User ──▶ POST /scheduled-messages ──▶ Messaging Service
                                           │
                                     ┌─────▼──────┐
                                     │ Scheduling  │
                                     │ Service     │
                                     │ (via gRPC)  │
                                     └─────┬──────┘
                                           │
                                     À l'heure prévue
                                           │
                                     ┌─────▼──────┐
                                     │ Envoi du   │
                                     │ message    │
                                     └────────────┘
```

Le messaging-service crée un job dans le scheduling-service qui envoie le message à l'heure voulue.
