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

### UserChannel

```
user:<user_id>
```

Reçoit les notifications globales de l'utilisateur (invitations, etc.).

## Presence

Le module Presence de Phoenix permet de tracker les utilisateurs en ligne et leur statut de typing en temps réel.
