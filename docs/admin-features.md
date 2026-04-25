# Fonctionnalités admin

## Endpoints admin

```
GET  /messaging/api/v1/reports/queue    - File d'attente modération
GET  /messaging/api/v1/reports/stats    - Statistiques
PUT  /messaging/api/v1/reports/:id/resolve - Résoudre un signalement
POST /messaging/api/v1/conversations/:id/sanctions - Sanctionner
DELETE /messaging/api/v1/conversations/:id/sanctions/:id - Lever sanction
```

L'accès admin est vérifié via le plug `RequireAdmin`.
