# Messages programmés

## Endpoints

```
GET    /messaging/api/v1/messages/scheduled      — Lister ses messages programmés
POST   /messaging/api/v1/messages/scheduled      — Créer un message programmé
PATCH  /messaging/api/v1/messages/scheduled/:id  — Modifier
DELETE /messaging/api/v1/messages/scheduled/:id  — Supprimer
```

## Flux

```
User ──▶ POST /messages/scheduled ──▶ Messaging Service
                                           │
                                     Stockage en DB
                                           │
                                     À l'heure prévue
                                           │
                                     ┌─────▼──────┐
                                     │ Envoi du   │
                                     │ message    │
                                     └────────────┘
```

Le scheduling est géré en interne par le ScheduledMessageController.
