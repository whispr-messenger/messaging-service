# Cycle de vie d'un message

```
Envoi ──▶ Stockage DB ──▶ Modération ──▶ Distribué
                               │
                          Rejeté? ──▶ Signalé
```

Un message passe par la modération avant d'être visible par les autres membres.
