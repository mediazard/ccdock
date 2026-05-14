# ccdock — Parallel Docker workspaces for Claude Code

A Claude Code plugin that spawns isolated, parallel Docker workspaces for any compose-based project. Each "dock" gets its own DB, ports, and Caddy wildcard route — multiple agents (or humans) can work on different branches simultaneously without colliding.

## Concept

A **dock** = jj/git worktree + isolated Docker compose stack + Caddy wildcard route.

Multiple docks run in parallel against the same machine, each with:

- Own `COMPOSE_PROJECT_NAME` → own containers/networks/volumes (auto-namespaced)
- Own restored DB (from a pre-generated dump of main's data)
- Own cloned `node_modules` volume
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

Place a `.dock.yml` at your project root. See `.dock.example.yml` for the full schema:

```yaml
project_name: my-app
base_host: dev.localhost
image_name: my-app
db_name: my_app_development
```

Your project's `docker-compose.yml` must support workspace parameterization:

- `ports: ["${WEB_PORT:-0}:3000"]` on the web service (dynamic ports for workspaces)
- `image: my-app:${IMAGE_TAG_VAR:-latest}` (per-workspace image tags optional but useful for CI caching)

That's it. From inside your project run:

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
