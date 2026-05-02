# Schéma base de données

## Tables principales

```
┌───────────────┐     ┌──────────────┐     ┌──────────────┐
│ conversations │────▶│   messages   │────▶│  reactions   │
│               │     │              │     │              │
│ - id          │     │ - id         │     │ - id         │
│ - type        │     │ - content    │     │ - emoji      │
│ - created_at  │     │ - sender_id  │     │ - user_id    │
└───────┬───────┘     │ - conv_id    │     │ - message_id │
        │             └──────────────┘     └──────────────┘
        │
        ▼
┌───────────────┐
│    members    │
│               │
│ - user_id     │
│ - conv_id     │
│ - role        │
└───────────────┘
```
