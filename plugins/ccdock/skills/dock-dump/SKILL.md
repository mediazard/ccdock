---
name: dock-dump
description: Pre-generate the database dump that /dock uses to seed new workspaces. Run this whenever you want fresh data for the next workspace creation. Required at least once before /dock will work.
---

# /dock-dump — Pre-generate the workspace DB seed

Runs `pg_dump --no-owner --no-acl` against the project's main Postgres container and writes a gzipped SQL dump at the configured `dump_path` (typically `tmp/dock-dump.sql.gz`).

## Invocation

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/dump
```

The script reads project-specific values (db_name, db_user, db_service, dump_path) from `.dock.yml` at the project root.

## Pre-requirements

- A `.dock.yml` at the project root.
- The main project's compose stack must be running with the `db_service` (typically `postgres`) container healthy.

## What gets dumped

- All schemas + data from the configured `db_name`.
- `--no-owner` and `--no-acl` strip `ALTER TABLE ... OWNER` and `GRANT` statements that reference production-only roles (e.g. `app_users`). Workspaces use the default `postgres` superuser and don't need the production access-control model.

## When to re-run

- Before creating the first dock of the day (so workspace data is reasonably fresh).
- After any major migration in main you want reflected in new docks.
- After `make sync` (or equivalent prod-data sync), if you want subsequent docks to see the freshly-synced data.

Existing docks are NOT affected — they have their own independent volumes. Re-dumping only affects future `/dock` invocations.
