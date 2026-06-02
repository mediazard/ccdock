# ccdock — Parallel Docker workspaces for Claude Code

A Claude Code plugin that spawns isolated, parallel Docker workspaces for any compose-based project. Each "dock" gets its own DB, ports, and Caddy wildcard route — multiple agents (or humans) can work on different branches simultaneously without colliding.

## Concept

A **dock** = jj/git worktree + isolated Docker compose stack + Caddy wildcard route.

Multiple docks run in parallel against the same machine, each with:

- Own `COMPOSE_PROJECT_NAME` → own containers/networks/volumes (auto-namespaced)
- Own restored DB (from a pre-generated dump of main's data)
- Own scoped named volumes (optional: clone selected named volumes from main via `clone_volumes:` for warm-start speed)
- Wildcard Caddy route at `*.<slug>-<base_host>` → unique per-workspace dynamic web port

A **captain** Claude Code session (the one you're already talking to) orchestrates the docks. Workers run in their own Claude Code sessions, one per dock, with cctop + this plugin's Notification/Stop hooks surfacing "waiting for input" status back to the captain.

The captain auto-observes worker docks: a `UserPromptSubmit` hook scans the shared inbox and injects new worker-question events into the captain's next prompt (one surface per event, per question). No polling needed — just type, and you'll see anything pending. `/docks` is still the on-demand status table.

## Skills

| Skill | What it does |
|---|---|
| `/dock <input>` | Create a new dock from a branch path, ticket ID, or free-form description |
| `/docks` | List active docks with status, URL, ticket |
| `/undock <slug>` | Destroy a dock — containers, volumes, Caddy route, inbox |
| `/dock-dump` | Pre-generate the DB dump that `/dock` uses to seed new workspaces |

## Install

### From GitHub (recommended — for you and your colleagues)

Add to `~/.claude/settings.json`:

```json
"extraKnownMarketplaces": {
  "ccdock": {
    "source": {
      "source": "github",
      "repo": "mediazard/ccdock"
    }
  }
},
"enabledPlugins": {
  "ccdock@ccdock": true
}
```

Restart Claude Code (or `/plugins reload` if available). Claude Code clones
`git@github.com:mediazard/ccdock.git` into its plugin cache and exposes the four
skills (`/dock`, `/docks`, `/undock`, `/dock-dump`) plus the Notification/Stop
hooks. To pull the latest plugin version later, run `/plugins update ccdock`.

Private repo? Ensure your colleagues have read access on GitHub and that their
local git can clone via SSH (`ssh -T git@github.com` should succeed).

### Pin to a specific version (optional)

```json
"extraKnownMarketplaces": {
  "ccdock": {
    "source": {
      "source": "github",
      "repo": "mediazard/ccdock",
      "ref": "v0.1.0"
    }
  }
}
```

### From a local checkout (for plugin development)

```json
"extraKnownMarketplaces": {
  "ccdock": {
    "source": { "source": "directory", "path": "~/path/to/ccdock" }
  }
}
```

### Required runtime dependencies

The plugin shells out to these — install them once per machine:

- Ruby ≥ 3.0 with the `thor` gem (`gem install thor`). Standard library covers the rest.
- `docker` + `docker compose` v2.
- `jq` (used by the notify hook).
- Caddy running on the host with its admin API at `localhost:2019`.
- `jj` (preferred) or `git` for worktrees.

## Adopting in a project

Place a `.dock.yml` at your project root. The minimum is three keys; everything else has sensible generic defaults (see `.dock.example.yml` for the full schema).

```yaml
project_name: my-app          # must match your main stack's COMPOSE_PROJECT_NAME
base_host: dev.localhost      # workspaces reachable at *.<slug>-<base_host>
db_name: my_app_development   # pg_dump source + restore target
```

### Compose requirements

Your project's `docker-compose.yml` must let ccdock-managed workspaces override two things at runtime:

```yaml
services:
  web:
    ports:
      - "${WEB_PORT:-0}:3000"           # dynamic host port in workspaces; main pins via .env (substitution source)
    image: my-app:${IMAGE_TAG:-latest}  # optional: per-workspace image tags (useful for CI cache; defaults to :latest locally)
    env_file:
      - .env
      - .env.local                       # MUST be loaded via env_file (not duplicated in `environment:`)
```

**Main keeps host port 3000 bound.** Set `WEB_PORT=3000` in main's **`.env`** — that's the file compose auto-loads for `${VAR}` substitution. `.env.local` is loaded via `env_file:` for container env only and does NOT reach compose's substitution layer, so a `WEB_PORT` there would silently have no effect on host port mapping. Workspaces leave the substitution unset (`WEB_PORT=0` written to workspace `.env`) → Docker assigns a dynamic port → ccdock registers a Caddy wildcard route at `*.<slug>-<base_host>` pointing at the dynamic port. Main's host:3000 binding is independent and stable.

**If your project uses a Caddy-auto-registration gem** (e.g. `rails_caddy_dev`, which gates on `ENV.key?('RAILS_CADDY_DEV')` — older versions used `ENV.key?('DEVCADDY')`):

- Set `RAILS_CADDY_DEV=1` in main's `.env.local`, NOT in compose's `environment:` block. Compose's `environment:` overrides `env_file:`, which would prevent ccdock from stripping the key in workspace containers.
- Main's web container needs host:3000 stably bound (above). The gem's auto-route dials `:3000` on the host — that has to be main's web.
- Set `disable_rails_caddy_dev_in_workspace: true` in `.dock.yml` (opt-in; default `false`). ccdock strips both `RAILS_CADDY_DEV` and the legacy `DEVCADDY` from each workspace's `.env` + `.env.local` so the gem doesn't load there and doesn't register a competing route. (The old key name `disable_devcaddy_in_workspace` still works as an alias.)

**If your project does NOT use a Caddy-auto-registration gem,** you can ignore the `RAILS_CADDY_DEV` notes. ccdock's wildcard route registration is the only Caddy traffic for workspaces; main is configured however you normally configure it.

### Quick start

From inside your project run:

```
/dock-dump            # one-time per fresh-data run
/dock sc-12345        # spawn a workspace
/docks                # list active docks
/undock sc-12345      # tear down
```

## Architecture

```
project-root/
├── .dock.yml                                # project-specific config (committed)
├── docker-compose.yml                       # has ${WEB_PORT:-0} param, etc.
└── ...

ccdock-plugin-root/                          # this repo
├── .claude-plugin/marketplace.json
└── plugins/ccdock/
    ├── .claude-plugin/plugin.json
    ├── hooks/hooks.json                     # Notification + Stop + UserPromptSubmit
    ├── skills/{dock,docks,undock,dock-dump}/SKILL.md
    └── scripts/
        ├── cli                              # thin Thor entrypoint
        ├── dump                             # bash, reads .dock.yml for project values
        ├── notify                           # bash hook — worker writes to inbox
        ├── observer                         # bash hook — captain reads inbox, injects context
        └── lib/dock/
            ├── config.rb                    # discovers + parses .dock.yml
            ├── slug.rb                      # branch → slug derivation
            ├── workspace.rb                 # jj/git worktree create + detect
            ├── env_files.rb                 # workspace .env / .env.local rewrite
            ├── caddy.rb                     # admin API client
            ├── docker.rb                    # volume + compose helpers
            ├── fingerprint.rb               # tamper-guard for destroy
            ├── inbox.rb                     # ~/.claude/docks/inbox JSONL
            └── commands/{base,start,list,destroy}.rb
```

## Security

- Slugs are constrained to `[a-z0-9][a-z0-9-]{0,62}` and re-validated at every boundary (CLI, Caddy admin API, inbox path, hook script). Path-traversal / shell-injection payloads in `/dock <input>` and in on-disk `.dock/slug` markers are rejected silently.
- `.dock.yml` paths are forbidden from containing `..` segments or absolute paths.
- `restore_dump` streams gzip → psql via `Open3.pipeline` — no shell interpolation.
- Inherited `.env*` and `.claude/settings.local.json` files are `chmod 0600` after copy.
- The Caddy admin API is assumed local-only (default Caddy binding); do not expose `:2019` on a shared host.
- Hooks fire under your user account — review `hooks/hooks.json` before installing on a shared machine.

Report issues by opening a GitHub issue or contacting the author directly.

## License

MIT — see [LICENSE](LICENSE).
