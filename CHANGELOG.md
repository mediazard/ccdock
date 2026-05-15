# Changelog

## 0.2.0 — 2026-05-15

**Breaking — generic-first config.** London (the original ccdock user) was
leaking project-specific assumptions into the defaults. Cleaned that up so the
plugin honestly fits any compose-based project.

- `image_name` removed from `REQUIRED_KEYS` (it was declared required but never
  read by any code). The accessor is gone; any value in existing `.dock.yml` is
  silently ignored.
- `node_modules_source` removed. Replaced by `clone_volumes:` — a list of named
  volume basenames to clone from `<project_name>_<name>` → `<slug>_<name>`.
  Default `[]`: workspaces start with empty named volumes and rely on the image
  build to populate them. Set this only if you want the warm-start optimization.
- `disable_devcaddy_in_workspace` default flipped from `true` → `false`. Only
  Rails projects with a `rails_caddy_dev`-style gem need it; non-Rails projects
  no longer get an unexplained `DEVCADDY` strip behaviour by default.
- `base_project` no longer auto-derived from `project_name`. When unset (the new
  default), `PROJECT_NAME` and `WORKROOM_NAME` are NOT written into the
  workspace `.env` — they're Rails-ish env vars that generic projects don't
  need. Set `base_project: <name>` to opt in.
- `destroy` now removes one `<slug>_<basename>` volume per `clone_volumes` entry
  (instead of hardcoded `<slug>_node_modules`). No-op when `clone_volumes: []`.
- Documentation rewritten: `.dock.example.yml` now shows the three required
  keys followed by clearly-commented opt-ins; README's "Adopting in a project"
  section reflects the smaller required surface.
- Captain observer role: new `scripts/observer` bash script wired to the
  `UserPromptSubmit` hook. On each captain prompt it scans
  `~/.claude/docks/inbox/*.jsonl` for new `question` events (per-slug cursor
  at `~/.claude/docks/captain-cursor.json`) and injects a
  `<ccdock-worker-events>` block as additional prompt context. Worker
  sessions self-exit. Idle/Stop events are not surfaced into context — they
  stay visible via `/docks`.

### Migration from 0.1.0

For the London project (or anyone with a 0.1.0 `.dock.yml`), edit your config:

```yaml
# Remove if present — silently ignored now:
# image_name: <value>

# Replace this:
# node_modules_source: london_node_modules
# With:
clone_volumes:
  - node_modules

# Add if you rely on PROJECT_NAME / WORKROOM_NAME env vars:
base_project: my-app

# Add if you use rails_caddy_dev (or similar DEVCADDY-gated gem):
disable_devcaddy_in_workspace: true
```

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
