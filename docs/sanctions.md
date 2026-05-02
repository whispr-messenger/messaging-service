# Système de sanctions

## Flux

```
Signalement ──▶ Report ──▶ Analyse modération
                                │
                          ┌─────▼─────┐
                          │ Sanction? │
                          └─────┬─────┘
                           oui  │  non
                          ┌─────┼─────┐
                          │           │
                     Mute/Ban    Classé
```

## Types de sanctions

| Type | Effet |
|------|-------|
| mute | L'utilisateur ne peut plus envoyer de messages |
| ban | L'utilisateur est exclu de la conversation |
