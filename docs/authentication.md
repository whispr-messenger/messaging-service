# Authentification

## JWKS

Le messaging-service vérifie les tokens JWT via le endpoint JWKS de l'auth-service.

```
Requête + JWT ──▶ Authenticate Plug ──▶ Fetch JWKS (caché)
                                              │
                                        Token valide?
                                         oui │ non
                                        ┌────┼────┐
                                        │        │
                                   Autorisé   401
```

## Cache JWKS

Les clés publiques sont cachées via le GenServer `JwksCache` pour éviter de fetch à chaque requête.
