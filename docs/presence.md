# Presence

## Fonctionnement

Le module Presence de Phoenix tracker les utilisateurs connectés.

```
User se connecte ──▶ Presence.track ──▶ État "online"
                                            │
                                    Broadcast à tous
                                    les contacts

User se déconnecte ──▶ Presence.untrack ──▶ État "offline"
```

## Données trackées

- Status en ligne / hors ligne
- Dernière activité
- Typing indicator par conversation
