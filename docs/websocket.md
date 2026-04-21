# WebSocket

## Channels

Le messaging-service utilise Phoenix Channels pour le temps réel.

### Connexion

```
wss://whispr.fr/socket/websocket
```

Le client doit fournir un token JWT valide pour s'authentifier.

### ConversationChannel

```
conversation:<conversation_id>
```

Événements :
- `new_message` — Nouveau message reçu
- `typing` — Un utilisateur est en train d'écrire
- `message_read` — Message lu
