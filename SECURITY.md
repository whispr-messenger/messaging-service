# Sécurité

## Authentification

Les requêtes sont authentifiées via JWT (vérification JWKS depuis l'auth-service).

## Mesures

- Vérification des tokens via JWKS
- Rate limiting sur les endpoints
- Validation des entrées
- Modération automatique du contenu via le moderation-service
