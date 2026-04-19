# Contribuer au Messaging Service

## Lancer le projet

```bash
just up dev
```

## Stack

Le service est écrit en Elixir/Phoenix.

## Conventions

- Conventional commits
- Branches : `WHISPR-XXX-description`
- Format : `mix format`
- Lint : `mix credo --strict`

## Tests

```bash
mix test
mix coveralls
```

## Structure du projet

```
lib/
├── whispr_messaging/          # Logique métier
│   ├── conversations.ex
│   ├── messages.ex
│   └── moderation/
└── whispr_messaging_web/      # Couche web
    ├── controllers/
    ├── channels/
    └── plugs/
```
