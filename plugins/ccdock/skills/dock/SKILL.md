---
name: dock
description: Create a new dock — an isolated, parallel Docker workspace for the current compose-based project. Each dock gets its own DB, ports, and Caddy wildcard route. Use when starting work on a new ticket or feature so the worker session has its own isolated environment.
---

# /dock — Spawn a new dock workspace

Creates a parallel, isolated Docker stack of the current project (defined by `.dock.yml` at the project root). Each dock gets its own Postgres, Redis, node_modules, and a Caddy wildcard route at `*.<slug>-<base_host>`.

## Usage

The user invokes `/dock <input>`. Input can be:

- A branch path (e.g. `user/sc-12345/feature-name`) — slug becomes `sc-12345`
- A bare ticket ID (e.g. `sc-12345`) — slug becomes `sc-12345`
- A free-form description (e.g. `fix the broken foo`) — slug auto-generated (`happy-otter`)

If the slug already exists, a numeric suffix is appended (`sc-12345-1`, `sc-12345-2`).

## What it does

1. Verifies `tmp/dock-dump.sql.gz` (or whatever `dump_path` is configured) exists. If missing, refuses with a pointer to run `/dock-dump` first.
2. Creates a jj workspace at `<worktree_dir>/<slug>/` (or git worktree fallback). Inherits the current working-copy state via `jj workspace add -r @`.
3. Copies `.env`, `.env.local`, `.bundle`, `.claude/settings.local.json` from the project root.
4. Sed-modifies the copied env files for workspace identity (COMPOSE_PROJECT_NAME, HOST_DOMAIN, dynamic ports).
5. Brings up postgres + redis, restores the dump.
6. Clones the configured `node_modules_source` volume.
7. Brings up web + worker — entrypoint runs `db:prepare` automatically to apply any pending migrations against the restored schema.
8. Polls web health.
9. Registers a Caddy wildcard route at `*.<slug>-<base_host>`.
10. Writes `.dock/{metadata.json, fingerprint, slug}` in the workspace.

## Invocation

Run from any directory inside a project that has `.dock.yml`:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cli start "<input>" --description "<optional context>"
```

After the script returns, show the user the URL and how to open the worker.

## Pre-requirements

- A `.dock.yml` at the project root.
- The project's main compose stack must have been run once (so the source `node_modules` Docker volume exists, otherwise pnpm install runs on first up).
- Caddy must be running on host with admin API at `localhost:2019` (project's responsibility).
- `tmp/dock-dump.sql.gz` (or configured `dump_path`) must exist — run `/dock-dump` if not.

## Worker question routing

Each dock workspace has Notification/Stop hooks (inherited from this plugin) that write to `~/.claude/docks/inbox/<slug>.jsonl`. Use `/docks` to see which docks are waiting. cctop's menubar surfaces the "waiting for input" status independently.
