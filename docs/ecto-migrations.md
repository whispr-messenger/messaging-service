# Migrations Ecto

## Commandes

```bash
# Créer une migration
mix ecto.gen.migration <nom>

# Exécuter les migrations
mix ecto.migrate

# Rollback
mix ecto.rollback
```

## Convention

Les migrations sont dans `priv/repo/migrations/`. Chaque migration est timestampée.
