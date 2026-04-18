# Messaging Service

> Add the ArgoCD badge here once deployed

---

- [Documentation]()
- [Swagger UI]()
- [ArgoCD UI]()
- [CodeCov]() (SonarQube is not available for Elixir)

## Description

This microservice is responsible of all messaging tasks for the Whispr Messenger system.

It handles real-time conversations, message delivery, reactions, attachments, scheduled messages, and content moderation via integration with the moderation-service.

## Tech Stack

- **Langage** : Elixir 1.18+
- **Framework** : Phoenix + OTP
- **Base de données** : PostgreSQL via Ecto
- **Cache** : Redis
- **Tests** : ExUnit + ExCoveralls

## Installation

The repository uses `just` a custom recipe runner (like `make` in C lang) to provide useful scripts.

Once you have `just` and `docker` installed on your computer you can start the development server with:

```sh
just up dev
```

## Architecture

```
┌──────────────┐     ┌───────────────────┐     ┌──────────────┐
│  Mobile App  │────▶│ Messaging Service │◀───▶│ Auth Service │
└──────────────┘     └────────┬──────────┘     └──────────────┘
                              │
                    ┌─────────┼──────────┐
                    │         │          │
              ┌─────▼──┐ ┌───▼────┐ ┌───▼──────────┐
              │ Postgres│ │ Redis  │ │ Moderation   │
              └────────┘ └────────┘ │ Service      │
                                    └──────────────┘
```

## API Endpoints

### REST

- `POST /conversations` — Créer une conversation
- `GET /conversations/:id` — Récupérer une conversation
- `POST /messages` — Envoyer un message
- `GET /conversations/:id/messages` — Lister les messages
- `POST /messages/:id/reactions` — Ajouter une réaction
- `POST /reports` — Signaler un contenu

### WebSocket

- `conversation:lobby` — Présence et typing indicators
- `conversation:<id>` — Messages en temps réel par conversation

## Testing

```bash
mix test
mix coveralls
```
