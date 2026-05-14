# Changelog

## Unreleased

- Captain observer role: new `scripts/observer` bash script wired to the
  `UserPromptSubmit` hook. On each captain prompt it scans
  `~/.claude/docks/inbox/*.jsonl` for new `question` events (per-slug cursor
  at `~/.claude/docks/captain-cursor.json`) and injects a
  `<ccdock-worker-events>` block as additional prompt context. Worker
  sessions self-exit. Idle/Stop events are not surfaced into context — they
  stay visible via `/docks`.

## 0.1.0 — 2026-05-14

Initial public release.

- Four skills (`/dock`, `/docks`, `/undock`, `/dock-dump`) for spawning parallel
  Docker workspaces from a single Claude Code session.
- Notification + Stop hooks that surface worker-session status back to the
  captain via a per-slug JSONL inbox.
- `.dock.yml` driven config — no project-specific literals in the plugin.

### Security hardening

- Strict slug validation (`[a-z0-9][a-z0-9-]{0,62}`) enforced at every boundary:
  CLI args, on-disk `.dock/slug`, Caddy admin API, inbox path.
- `restore_dump` runs `gunzip | psql` via `Open3.pipeline` — argv arrays only,
  no shell interpolation, no `shellescape` dependence.
- `.dock.yml` rejects relative-path keys (`worktree_dir`, `dump_path`) that
  contain `..` segments or are absolute.
- Inherited `.env*` and `.claude/settings.local.json` are `chmod 0600` after
  copy into a workspace.
- `notify` bash script reads only the first line of `.dock/slug`, strips
  whitespace, and validates against the same slug regex Ruby enforces. Bad
  marker content causes a silent exit (no inbox write).
- Caddy `register_wildcard` validates port range before constructing the
  reverse-proxy upstream.
- Behavioural tests added for all the above (slug regex, config rejection,
  inbox/Caddy slug validation, notify bats integration tests).
