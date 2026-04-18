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

## Installation

The repository uses `just` a custom recipe runner (like `make` in C lang) to provide useful scripts.

Once you have `just` and `docker` installed on your computer you can start the development server with:

```sh
just up dev
```
