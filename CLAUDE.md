# AI Agent Workflow — whispr-messenger/messaging-service

This document describes the full development workflow an AI agent must follow
when picking up and completing a Jira ticket for this repository.

---

## 0. Prerequisites

- Jira cloud ID: `82ae2da5-7ee5-48f7-8877-a644651cd84b`
- GitHub org/repo: `whispr-messenger/messaging-service`
- Default base branch: `main`
- Language: **Elixir / Phoenix** (`mix`)

---

## 1. Pick the ticket

1. Use `mcp__atlassian__getJiraIssue` to fetch the target ticket (e.g. `WHISPR-290`).
2. Read the **description**, **acceptance criteria**, and **priority** carefully.
3. Use `mcp__atlassian__getTransitionsForJiraIssue` to list available transitions.
4. Transition the ticket from "À faire" → "En cours" using `mcp__atlassian__transitionJiraIssue`
   with the transition id whose `name` is `"En cours"` (currently `"21"`).

---

## 2. Prepare the branch (worktree)

Each ticket **must** be worked on in a dedicated
[git worktree](https://git-scm.com/docs/git-worktree) stored under `.worktrees/`
(ignored by git). This keeps the main checkout clean and allows parallel work on
multiple tickets.

```bash
git fetch origin main
git worktree add .worktrees/<TICKET-KEY>-<short-kebab-description> -b <TICKET-KEY>-<short-kebab-description> origin/main
cd .worktrees/<TICKET-KEY>-<short-kebab-description>
```

Branch naming convention: `WHISPR-XXX-short-description-of-the-fix`

Example:
```bash
git worktree add .worktrees/WHISPR-468-implement-conversation-search -b WHISPR-468-implement-conversation-search origin/main
cd .worktrees/WHISPR-468-implement-conversation-search
```

### Cleanup after merge

Once the PR is merged and the ticket is closed, remove the worktree:

```bash
git worktree remove .worktrees/<TICKET-KEY>-<short-kebab-description>
git branch -d <TICKET-KEY>-<short-kebab-description>
```

---

## 3. Implement the fix

1. **Explore first** — run `mcp__gitnexus__query` with the ticket's key concepts to find relevant execution flows before opening any file:
   ```json
   { "query": "<ticket concept e.g. 'conversation message search'>", "limit": 5 }
   ```
2. **Check impact before editing** — for every symbol you plan to modify, run `mcp__gitnexus__impact` and report the blast radius to the user before touching the code:
   ```json
   { "target": "<symbolName>", "direction": "upstream" }
   ```
   Stop and warn the user if the result is HIGH or CRITICAL risk.
3. Read all relevant files before modifying anything.
4. Make the smallest change that fully addresses the ticket.
5. Do not refactor unrelated code or change formatting outside the touched lines.
6. Prefer editing existing files over creating new ones.

---

## 4. Write tests

Tests live in the `test/` directory.

| Kind | Location | Pattern |
|------|----------|---------|
| Unit | `test/<module>/` | `*_test.exs` |
| Controller | `test/<app>_web/controllers/` | `*_controller_test.exs` |

### Rules

- **Test behaviour, not implementation.** Assert on observable outcomes
  (response body, HTTP status codes, database state) rather than internal call sequences.
- Use `Ecto.Adapters.SQL.Sandbox` for database isolation in tests.
- Mock external services (JWKS, Redis pub/sub) via `Mox` or process-based stubs.

### Run tests

```bash
# All tests
mix test

# Specific file
mix test test/whispr_messaging/conversations_test.exs

# With coverage
mix coveralls
```

All tests must be green before committing.

---

## 5. Format and lint

```bash
# Check formatting (CI enforces this)
mix format --check-formatted

# Auto-fix formatting
mix format

# Credo strict lint
mix credo --strict
```

All three must pass before committing.

---

## 6. Commit

Stage only the files you changed:

```bash
git add <file1> <file2> ...
```

Commit message format (Conventional Commits):

```
<type>(<scope>): <short imperative summary>

<optional body — explain the why, not the what>
```

- **type**: `fix`, `feat`, `refactor`, `test`, `docs`, `chore`
- **scope**: module name, e.g. `conversations`, `messages`, `auth`
- Do **not** mention Claude, AI, or any tooling in the commit message.

Example:
```
feat(conversations): implement conversation search endpoint
```

---

## 7. Push

```bash
git push -u origin <branch-name>
```

After every push to an existing PR branch, **immediately**:

1. Copilot Code Review is triggered automatically by CI on each push — do **not** manually request a new review unless explicitly asked by maintainers or if the automation fails.

2. CI runs `mix compile --warnings-as-errors` — any warning is a build failure. Fix all compiler warnings before pushing.

3. Check CI with:

```bash
gh pr checks <PR-number> --repo whispr-messenger/messaging-service
```

Fix any failing checks before proceeding.

---

## 8. Open a Pull Request

### PR title must include the Jira ticket key

Every PR title **must** contain the Jira ticket key in brackets: `[WHISPR-XXX] <title>`.

Example: `[WHISPR-468] feat(conversations): implement conversation search endpoint`

If no ticket is associated with the PR:

1. Search Jira for an existing ticket that matches the PR scope using
   `mcp__atlassian__searchJiraIssuesUsingJql`.
2. If a matching ticket is found, use its key.
3. If no matching ticket exists, **create a new ticket** using
   `mcp__atlassian__createJiraIssue` with a summary and description derived from
   the PR's scope, then use the new key.
4. Rename the PR title to include the resolved key: `[WHISPR-XXX] <title>`.

### Create the PR

Use `mcp__github__create_pull_request`:

```json
{
  "owner": "whispr-messenger",
  "repo": "messaging-service",
  "title": "[WHISPR-XXX] <same as commit title>",
  "head": "<branch-name>",
  "base": "main",
  "body": "## Summary\n- bullet 1\n- bullet 2\n\n## Test plan\n- [ ] mix test green\n- [ ] mix format --check-formatted clean\n- [ ] mix credo --strict clean\n\nCloses WHISPR-XXX"
}
```

---

## 8b. Process review comments

GitHub Copilot reviews the PR automatically on each push. Repeat the loop below
until no unresolved, non-outdated threads remain.

### Fetch open threads

Use `mcp__github__pull_request_read` with `method: "get_review_comments"`.
Filter to threads where **`is_resolved: false`** and **`is_outdated: false`**.

### For each open thread

1. **Read the comment carefully** — note whether it is labelled Blocking or Non-blocking.
2. **Decide**:
   - **Fix** — implement the change, commit, then reply citing the commit hash and what was done.
   - **Acknowledge / Won't fix** — reply with a clear rationale.
3. **Reply in the thread** using `mcp__github__add_reply_to_pull_request_comment`
   with `commentId` set to the ID of the **first** comment in the thread.

### Severity guide

| Label | Action |
|-------|--------|
| **Blocking** | Must be fixed or explicitly declined with justification before merge |
| **Non-blocking** | Should be fixed or acknowledged; declining is acceptable with rationale |
| *(unlabelled)* | Style/tidiness — fix if trivial, acknowledge otherwise |

### Merge gate

- All **blocking** threads resolved
- All **non-blocking** threads acknowledged
- CI green (`gh pr checks <PR-number> --repo whispr-messenger/messaging-service`)

---

## 9. Merge the PR

Once all CI checks are green, use `mcp__github__merge_pull_request`:

```json
{
  "owner": "whispr-messenger",
  "repo": "messaging-service",
  "pullNumber": <number>,
  "merge_method": "squash"
}
```

Always use **squash** merge to keep `main` history linear.

---

## 10. Close the Jira ticket

Use `mcp__atlassian__transitionJiraIssue` with the transition whose `name` is
`"Terminé"` (currently id `"31"`) to move the ticket to done.

---

## 11. Clean up worktree and return to main

```bash
cd /path/to/messaging-service
git worktree remove .worktrees/<TICKET-KEY>-<short-kebab-description>
git branch -d <TICKET-KEY>-<short-kebab-description>
```

---

## Jira transition IDs (current)

| Name | ID |
|------|----|
| À faire | `11` |
| En cours | `21` |
| Terminé | `31` |

These IDs are stable but can be verified with
`mcp__atlassian__getTransitionsForJiraIssue` if in doubt.

---

## Jira MCP — Usage Notes

### Tool parameter types

`mcp__atlassian__searchJiraIssuesUsingJql` requires:
- `maxResults`: **number**, not string (e.g. `10`, not `"10"`)
- `fields`: **array**, not string (e.g. `["summary", "status"]`, not `"summary,status"`)

### Current sprint

| Sprint | ID | Board ID |
|--------|----|----------|
| Sprint 6 | `200` | `34` |

### Tools that do NOT work

- `mcp__atlassian__jiraRead` — requires an `action` enum parameter, not a free-form URL; not useful for agile/sprint endpoints.
- `mcp__atlassian__fetch` — requires an `id` parameter; cannot be used for arbitrary REST calls.

---

## Elixir-specific notes

### Compiler warnings are errors in CI

`mix compile --warnings-as-errors` is enforced. Common pitfalls:
- Default arguments in private functions that are never used → remove the default.
- Unused variables → prefix with `_` or remove.
- Unreachable clauses in `with` / `case` → fix the pattern.

### JWKS authentication

The service uses a custom `JwksCache` GenServer to cache public keys from the auth-service JWKS endpoint. Authentication is done via the `WhisprMessagingWeb.Plugs.Authenticate` plug. Tokens are verified with `Joken` using EC P-256 keys.

### Database

PostgreSQL via Ecto. Use `Repo.transaction/2` for multi-step operations. Never interpolate user input in raw SQL — use parameterised queries or Ecto query DSL.

### Testing database isolation

Tests use `Ecto.Adapters.SQL.Sandbox` in `:manual` checkout mode. Each test that touches the DB must call `Ecto.Adapters.SQL.Sandbox.checkout(WhisprMessaging.Repo)`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **messaging-service**. Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "message search"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "get_conversation"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/messaging-service/context` | Codebase overview, check index freshness |
| `gitnexus://repo/messaging-service/clusters` | All functional areas |
| `gitnexus://repo/messaging-service/processes` | All execution flows |

<!-- gitnexus:end -->
