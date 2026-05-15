---
name: undock
description: Destroy a dock workspace — stops containers, removes its scoped Docker volumes, deletes the Caddy route, removes its inbox file. Does NOT remove the worktree directory itself (user runs `jj workspace forget` separately). Use when finished with a ticket and ready to reclaim resources.
---

# /undock — Tear down a dock workspace

Removes runtime artifacts for a dock. Leaves the workspace directory intact so the user can decide whether to fully reclaim it via `jj workspace forget` / `git worktree remove`.

## Invocation

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cli destroy <slug>
```

## What it does

1. Verifies `.dock/fingerprint` exists and matches recomputed fingerprint — refuses on mismatch (workspace was tampered with).
2. Refuses if slug is reserved (matches main project name, base project name, or anything in `reserved_slugs` from `.dock.yml`).
3. Checks `docker volume ls --filter label=...` — refuses if any volume name doesn't start with `<slug>_` (protects against the destroy operating on main's volumes).
4. `docker compose -p <slug> down -v` — stops containers, removes compose-scoped volumes.
5. Removes each `<slug>_<basename>` volume listed in `clone_volumes` (these were created outside compose, so `down -v` doesn't catch them).
6. Deletes the Caddy wildcard route by ID.
7. Removes `~/.claude/docks/inbox/<slug>.jsonl`.
8. Leaves the workspace directory at `<worktree_dir>/<slug>/` intact for review.

## Safety guards

- Reserved slug refusal (main project, base project, configured reserved list).
- Fingerprint mismatch refusal — protects against hand-edited `.env` repurposing.
- Volume-name guard catches the case where someone changed `COMPOSE_PROJECT_NAME` to main's.

## When to ask the user before destroying

If the dock currently has a pending question in its inbox (see `/docks` status), ask the user before destroying — they may want to switch to that dock and answer first.
