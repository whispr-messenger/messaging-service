# Gestion des erreurs

## Codes HTTP

| Code | Signification |
|------|---------------|
| 200 | OK |
| 201 | Créé |
| 400 | Requête invalide |
| 401 | Non authentifié |
| 403 | Non autorisé |
| 404 | Ressource introuvable |
| 422 | Entité non traitable |
| 429 | Rate limit |
| 500 | Erreur serveur |

## Format de réponse erreur

```json
{
  "error": "not_found",
  "message": "Conversation not found"
}
```
