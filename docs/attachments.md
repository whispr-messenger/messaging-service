# Pièces jointes

## Flux

```
Client upload ──▶ Media Service ──▶ URL signée
                                        │
Message + URL ──▶ Messaging Service ──▶ Stockage
                                        │
                                  Broadcast WS
                                  aux membres
```

Les fichiers ne transitent pas par le messaging-service, seulement les URLs.
