---
name: docks
description: List all currently running dock workspaces with their URLs, ticket descriptions, and worker status (question/idle). Use when checking which docks need attention, when deciding which dock to switch to, or to find an existing dock for a ticket before creating a new one.
---

# /docks — List active dock workspaces

Shows a table of running docks: slug, status (question/idle/—), URL, ticket info, age.

## Invocation

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cli list
```

## Output format

```
SLUG          STATUS    URL                                       TICKET     AGE
sc-10001      question  https://app.sc-10001-dev.localhost        sc-10001   2h
happy-otter   idle      https://app.happy-otter-dev.localhost     —          8m
```

Status sources:

- **Active docks:** identified by intersecting `docker compose ls` (Docker daemon truth) with the set of compose projects whose workspace dir has a `.dock/metadata.json` marker.
- **question/idle:** last event in `~/.claude/docks/inbox/<slug>.jsonl` written by the worker's Notification/Stop hook. `—` means no inbox file yet.

## Captain observer (automatic)

Each prompt the captain submits triggers a `UserPromptSubmit` hook that scans
the inbox for **new `question` events** (one per worker) since the last
surface, and injects a `<ccdock-worker-events>` block into the captain's
context. The block lists slug + timestamp + the worker's question message.

Cursor lives at `~/.claude/docks/captain-cursor.json`; each surfaced question
is recorded so it is shown at most once. `idle`/Stop events stay in the inbox
for `/docks` but are not injected — they would otherwise spam every prompt.

## When to suggest running this

- User asks "what docks are running"
- User mentions a ticket — check first whether a dock already exists for it
- A captain hook surfaces a pending question marker and wants context before responding
