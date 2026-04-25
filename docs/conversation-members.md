# Membres de conversation

## Endpoints

```
GET    /messaging/api/v1/conversations/:id/members          - Lister
POST   /messaging/api/v1/conversations/:id/members          - Ajouter
DELETE /messaging/api/v1/conversations/:id/members/:user_id - Retirer
```

## Rôles

| Rôle | Permissions |
|------|-------------|
| owner | Tout (supprimer conversation, gérer membres) |
| admin | Ajouter/retirer membres, modérer |
| member | Envoyer messages, réagir |
