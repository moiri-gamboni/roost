# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure. The target is a hardened Ubuntu 24.04 server with btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), and a Docker Compose stack for services.

## Script Execution

**`deploy.sh`** runs from your laptop and handles everything: provisioning via `hcloud` CLI, btrfs conversion (via rescue mode), and full server setup over SSH. It pauses for interactive auth (Tailscale, Claude Code OAuth, Cloudflare Tunnel). Idempotent and safe to re-run.

The script sources `.env` for configuration and logs to `logs/` (gitignored).

## Key Design Patterns

**Idempotency**: `deploy.sh` uses check-then-act for every section (`command -v`, `id -u`, `grep -q`, etc.) in the remote setup blocks. It is safe to re-run after partial failures or to apply changes.

**SSH helpers in deploy.sh**: `remote()` and `remote_tty()` run commands on the server. `remote_script()` runs a setup script from the deployed files directory. `remote_rescue()` handles rescue-mode SSH with relaxed host key checking.

**Shared environment via `files/_setup-env.sh`**: Sourced by every setup script. Reads `.env` values from the server copy, exports `USERNAME`, `HOME_DIR`, etc., and provides `as_user()` helper.

**No public ports**: The server has no open TCP ports. Tailscale handles private access; Cloudflare Tunnel handles public web traffic. The only public UDP port is 41641 (Tailscale WireGuard).

**`~/roost/` directory**: All synced state lives under `~/roost/`, making Syncthing configuration a single folder share. `CLAUDE_CONFIG_DIR=~/roost/claude` redirects Claude Code's config there.

## File Layout

- **`deploy.sh`** -- Single deploy script, run from your laptop
- **`files/`** -- Config files and templates deployed to the server
  - `_setup-env.sh` -- Shared environment sourced by every setup script
  - `settings.json` -- Claude Code settings with hook definitions (SessionStart/End, PreCompact, Stop, Notification)
  - `docker-compose.yml` -- Docker Compose stack template (envsubst-expanded on deploy)
  - `Caddyfile` -- Caddy reverse proxy config template
  - `glances.service` -- Systemd unit for Glances monitoring
  - `cron-self-host` -- Crontab entries for health checks, scheduled tasks, auto-update
  - `docker-tailscale.conf` -- Systemd drop-in to wait for Tailscale before Docker starts
  - `machines.json` -- Claude Code multi-machine coordination template
  - `hooks/` -- Shell scripts for Claude Code hooks and cron jobs
  - `setup/` -- Modular setup scripts (system, user, docker, claude, etc.)
- **`extras/`** -- Standalone utilities not part of the main setup flow
  - `hetzner-watch.sh` -- Polls Hetzner API for server type availability, sends ntfy alerts

## Server Directory Structure

```
~/roost/                    Syncthing-synced root
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts
│   ├── skills/learned/     Learned skills
│   ├── locks/              Session lock files
│   ├── machines.json       Multi-machine coordination
│   └── projects/           Session transcripts (auto-managed)
├── memory/                 Structured notes (grepai-indexed)
└── code/                   Project repositories
```

## Hook Architecture

Hooks are defined in `files/settings.json` and deployed to `~/roost/claude/hooks/`:

| Hook Event | Script | Purpose |
|---|---|---|
| SessionStart | `session-lock.sh` | Writes a lock file with hostname/tmux/PID metadata for multi-machine coordination |
| SessionEnd | `session-unlock.sh` | Removes the lock file |
| PreCompact | `reflect.sh` | Injects a prompt reminding the agent to save learnings before context compaction |
| Stop | `auto-commit.sh` | Stages tracked + new files, runs gitleaks, commits with session ID |
| Notification | `notify.sh` | Sends push notifications via local ntfy (with rate limiting and priority levels) |

Cron-triggered hooks (not Claude Code events):
- `health-check.sh` -- Checks Ollama, grepai, disk, swap, memory; alerts via ntfy
- `scheduled-task.sh` / `run-scheduled-task.sh` -- Runs Claude Code tasks in tmux windows
- `auto-update.sh` -- Weekly updates with btrfs snapshot before, ntfy summary after

## Docker Compose Stack

Deployed from `files/docker-compose.yml` template into `~/services/docker-compose.yml`:
- **Caddy** -- Reverse proxy bound to Tailscale IP (no public exposure)
- **cloudflared** -- Cloudflare Tunnel, mounts `~/.cloudflared/` read-only
- **ntfy** -- Push notifications on Tailscale IP port 2586
- **Syncthing** -- File sync for `~/roost/` (single volume)

All services bind to `${TAILSCALE_IP}` (from `~/services/.env`) instead of `0.0.0.0`.

## Configuration

All configuration lives in `.env` (copied from `.env.example`). Required vars: `HETZNER_API_TOKEN`, `SERVER_NAME`, `USERNAME`, `DOMAIN`. The `.env` file is gitignored.

## Shell Conventions

- All scripts use `set -euo pipefail` (except `hetzner-watch.sh` which omits `-e` so polling loops survive failed checks)
- Hook scripts read JSON from stdin via `cat` and parse with `jq`
- ntfy notifications go to `http://localhost:2586/claude-$(whoami)`
