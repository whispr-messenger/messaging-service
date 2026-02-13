# Changelog Agent

## 2026-02-13

### Configuration Docker
- Création et configuration de l'environnement Docker pour le développement.
- Fichiers créés/modifiés :
  - `docker/dev/Dockerfile`
  - `docker/dev/compose.yml`
  - `docker/dev/.env`
  - `docker/dev/redis.conf`

### Correction de Stabilité (DB Connection)
- Résolution des problèmes de connexion à la base de données lors des tâches asynchrones.
- Utilisation de `Task.Supervisor` pour gérer les processus enfants de manière robuste.
- Fichiers modifiés :
  - `lib/whispr_messaging/application.ex`

### Transmission de Messages
- Implémentation de la logique de transmission de messages avec déduplication et ordonnancement.
- Ajout de la gestion des indicateurs de statut (envoyé, distribué, lu).
- Fichiers modifiés :
  - `lib/whispr_messaging/conversations/conversation_server.ex`
  - `lib/whispr_messaging/services/message_service.ex` (ou équivalent selon l'implémentation)
