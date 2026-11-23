---
name: dock
description: Create a new dock — an isolated, parallel Docker workspace for the current compose-based project. Each dock gets its own DB, ports, and Caddy wildcard route. Use when starting work on a new ticket or feature so the worker session has its own isolated environment.
---

# /dock — Spawn a new dock workspace

Creates a parallel, isolated Docker stack of the current project (defined by `.dock.yml` at the project root). Each dock gets its own Postgres, Redis, scoped named volumes, and a Caddy wildcard route at `*.<slug>-<base_host>`.

## Usage

The user invokes `/dock <input>` (input is optional in a linked worktree, see In-place mode). Input can be:

- A branch path (e.g. `user/sc-12345/feature-name`) — slug becomes `sc-12345`
- A bare ticket ID (e.g. `sc-12345`) — slug becomes `sc-12345`
- A free-form description (e.g. `fix the broken foo`) — slug auto-generated (`happy-otter`)

If the slug already exists, a numeric suffix is appended (`sc-12345-1`, `sc-12345-2`).

## In-place mode

If you run `/dock` from inside an existing linked git worktree (made by Orca, Conductor, `git worktree add`, or any other tool), that worktree is docked in place:

- No worktree is created. The slug is the folder name, normalised (`My_Worktree` becomes `my-worktree`). If the name holds a ticket id (`sc-12345` or `story-12345`), the slug is `sc-12345`. Other long names are cut so `<slug>-<base_host first label>` stays within the 63-char DNS label limit.
- `<input>` is optional and ignored.
- `.dock.yml` is read from the main checkout.
- Reruns are safe. If the stack already exists, the volume clone is skipped.
- A slug already used by a dock in another folder is refused.

## What it does

1. Creates a jj workspace at `<worktree_dir>/<slug>/` (or git worktree fallback). Inherits the current working-copy state via `jj workspace add -r @`.
2. Copies `.env`, `.env.local`, `.bundle`, `.claude/settings.local.json` from the project root.
3. Sed-modifies the copied env files for workspace identity (COMPOSE_PROJECT_NAME, HOST_DOMAIN, dynamic ports).
4. Brings up postgres + redis.
5. Clones any volumes listed in `clone_volumes` (empty by default — relies on the image build).
6. Builds web + worker with `--ssh default` when the host SSH agent has a key (`ssh-add -l`), so private git gems can be fetched. Then brings up web + worker. The app's entrypoint (e.g. Rails `db:prepare`) creates and seeds the DB. ccdock does nothing database-specific.
7. Polls web health.
8. Registers a Caddy wildcard route at `*.<slug>-<base_host>`.
9. Writes `.dock/{metadata.json, fingerprint, slug}` in the workspace.

## Invocation

Run from any directory inside a project that has `.dock.yml`:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cli start ["<input>"] --description "<optional context>"
```

After the script returns, show the user the URL and how to open the worker.

## Pre-requirements

- A `.dock.yml` at the project root.
- If `clone_volumes:` is configured, the source volumes must exist on the Docker daemon (e.g. main's compose stack has been brought up once so compose auto-created its named volumes). If a source volume is absent, the clone is a no-op and the workspace gets an empty volume — the image build (or first-run install) populates it.
- Caddy must be running on host with admin API at `localhost:2019` (project's responsibility).
- The app's entrypoint must create and seed the DB (e.g. Rails `db:prepare`).

## Worker question routing

Each dock workspace has Notification/Stop hooks (inherited from this plugin) that write to `~/.claude/docks/inbox/<slug>.jsonl`. Use `/docks` to see which docks are waiting. cctop's menubar surfaces the "waiting for input" status independently.
