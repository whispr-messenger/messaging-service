# Réactions

## Flux

```
User ──▶ POST /messages/:id/reactions
                │
          ┌─────▼────────┐
          │ Vérif message │
          │ existe        │
          └─────┬────────┘
                │
          ┌─────▼────────┐
          │ Ajout/Toggle  │
          │ réaction      │
          └─────┬────────┘
                │
          Broadcast WebSocket
          aux membres
```
