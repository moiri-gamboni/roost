# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure. The target is a hardened Ubuntu 24.04 server with btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), and native systemd services.

## Script Execution

**`deploy.sh`** runs from your laptop and handles everything: provisioning via `hcloud` CLI, btrfs conversion (via rescue mode), and full server setup over SSH. The only remaining manual step is Claude Code OAuth (done after deploy via `claude` on the server). Use `--yes` / `-y` to skip the confirmation prompt. Idempotent and safe to re-run.

The script sources `.env` for configuration, shows a pre-flight summary before provisioning, and logs to `logs/` (gitignored).

## Key Design Patterns

**Idempotency**: `deploy.sh` uses check-then-act for every section (`command -v`, `id -u`, `grep -q`, etc.) in the remote setup blocks. It is safe to re-run after partial failures or to apply changes.

**SSH helpers in deploy.sh**: `remote()` and `remote_tty()` run commands on the server. `remote_script()` runs a setup script from the deployed files directory. `remote_rescue()` handles rescue-mode SSH with relaxed host key checking.

**Shared environment via `files/_setup-env.sh`**: Sourced by every setup script. Reads `.env` values from the server copy, exports `USERNAME`, `HOME_DIR`, etc., and provides `as_user()` helper.

**Firewall model**: The Hetzner cloud firewall has a temporary SSH rule that exists only during deploys. `deploy.sh` adds it at the start and removes it at the end, so public SSH is locked out between deploys. UFW on the server allows SSH on port 22 (the cloud firewall controls whether traffic reaches it). Tailscale handles private access; Cloudflare Tunnel handles public web traffic. The only permanent public port is UDP 41641 (Tailscale WireGuard).

**`~/roost/` directory**: All synced state lives under `~/$ROOST_DIR_NAME/` (default `~/roost/`, configurable via `ROOST_DIR_NAME` in `.env`), making Syncthing configuration a single folder share. `CLAUDE_CONFIG_DIR=~/$ROOST_DIR_NAME/claude` redirects Claude Code's config there.

## File Layout

- **`deploy.sh`** -- Single deploy script, run from your laptop
- **`files/`** -- Config files and templates deployed to the server
  - `_setup-env.sh` -- Shared environment sourced by every setup script
  - `settings.json` -- Claude Code settings with hook definitions (SessionStart/End, PreCompact, Stop, Notification)
  - `Caddyfile` -- Caddy reverse proxy config template (envsubst-expanded on deploy)
  - `caddy-tailscale.conf` -- Systemd drop-in for Caddy to wait for Tailscale
  - `cloudflare-config.yml` -- Cloudflare Tunnel config template (envsubst-expanded on deploy)
  - `ntfy-server.yml` -- ntfy server configuration
  - `syncthing-tailscale.conf` -- Systemd drop-in for Syncthing to wait for Tailscale
  - `glances.service` -- Systemd unit for Glances monitoring
  - `ram-monitor.service` / `ram-monitor.timer` -- Systemd units for per-process RAM alerting (10s interval)
  - `cron-roost` -- Crontab entries for health checks, scheduled tasks, auto-update
  - `hooks/` -- Shell scripts for Claude Code hooks and cron jobs
    - `_hook-env.sh` -- Shared library: JSON input parsing (`hook_json`), ntfy helpers, rate limiting, logging
    - `reflect.md` -- Prompt injected by `reflect.sh` before context compaction
  - `setup/` -- Modular setup scripts (system, user, caddy, ntfy, syncthing, claude, etc.)
- **`extras/`** -- Standalone utilities not part of the main setup flow
  - `hetzner-watch.sh` -- Polls Hetzner API for server type availability, sends ntfy alerts

## Server Directory Structure

The directory name `roost` is configurable via `ROOST_DIR_NAME` in `.env`.

```
~/roost/                    Syncthing-synced root
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts
│   ├── skills/learned/     Learned skills
│   ├── locks/              Session lock files
│   └── projects/           Session transcripts (auto-managed)
├── memory/                 Structured notes (grepai-indexed)
└── code/                   Project repositories
```

## Hook Architecture

Hooks are defined in `files/settings.json` and deployed to `~/roost/claude/hooks/`:

| Hook Event | Script | Purpose |
|---|---|---|
| SessionStart | `session-lock.sh` | Writes a lock file with hostname/tmux/PID metadata for multi-machine coordination |
| SessionEnd | `session-unlock.sh` | Removes the lock file; auto-names unnamed sessions via `claude -p --model sonnet` (background) |
| PreCompact | `reflect.sh` | Injects a prompt reminding the agent to save learnings before context compaction |
| Stop | `auto-commit.sh` | Stages tracked + new files, runs gitleaks, commits with session ID |
| Notification | `notify.sh` | Sends push notifications via local ntfy (with rate limiting and priority levels) |

All hook scripts source `_hook-env.sh` which provides `hook_json()` for parsing Claude Code's JSON input, `ntfy_send()` for notifications (with journald fallback), `rate_limit_ok()` to prevent notification floods, and journald logging via `logger -t "$_HOOK_TAG"` (tags: `roost/<script-name>`).

Cron-triggered hooks (not Claude Code events):
- `health-check.sh` -- Checks Ollama, Caddy, ntfy, Syncthing, Tailscale, cloudflared, disk, inodes, swap; alerts via ntfy
- `scheduled-task.sh` / `run-scheduled-task.sh` -- Runs Claude Code tasks in tmux windows
- `auto-update.sh` -- Weekly updates with btrfs snapshot before, ntfy summary after (7-day cooldown, major version guard)
- `conflict-check.sh` -- Detects Syncthing conflict files in `~/roost/`, alerts via ntfy

Systemd timer (not cron):
- `ram-monitor.sh` -- Alerts when any process exceeds 3GB RSS (runs every 10s via `ram-monitor.timer`, tracks notified PIDs to avoid repeats)

## Native Services

All infrastructure runs as native systemd services installed via official apt repos:
- **Caddy** (`caddy.service`) -- Reverse proxy bound to Tailscale IP via `default_bind` in Caddyfile. Config at `/etc/caddy/Caddyfile`.
- **cloudflared** (`cloudflared.service`) -- Cloudflare Tunnel. Config at `/etc/cloudflared/config.yml`.
- **ntfy** (`ntfy.service`) -- Push notifications on `127.0.0.1:2586` (localhost only). Config at `/etc/ntfy/server.yml`.
- **Syncthing** (`syncthing@$USERNAME.service`) -- File sync for `~/roost/`. GUI on `localhost:8384`, sync on Tailscale IP port 22000.

Caddy and Syncthing have systemd drop-ins that wait for Tailscale before starting. Updates are handled by `apt upgrade` (via auto-update.sh and unattended-upgrades).

Additionally, `claude-config.sh` installs the `dangerous-command-blocker` PreToolUse hook (via `claude-code-templates`), and `harden-hooks.sh` can make hook scripts and settings immutable via `chattr +i` to protect against Syncthing tampering.

## Configuration

All configuration lives in `.env` (copied from `.env.example`). Required vars: `SERVER_NAME`, `USERNAME`, `DOMAIN`, `TAILSCALE_AUTHKEY`, `CLOUDFLARE_API_TOKEN`. Additional vars: `ROOST_DIR_NAME` (default `roost`), `CLOUDFLARE_ACCOUNT_ID` (optional, auto-detected), `CLOUDFLARE_TUNNEL_NAME` (defaults to `$ROOST_DIR_NAME`). SSH key is auto-selected interactively from Hetzner keys (or upload a new one); `SSH_KEY_NAME` in `.env` is no longer needed. Hetzner API auth is handled by `hcloud context create` (not stored in `.env`). Cloudflare tunnel creation and DNS routing use the Cloudflare API (no browser login or `cert.pem`). Use `--yes` / `-y` to skip the deploy confirmation prompt. The `.env` file is gitignored.

## Shell Conventions

- All scripts use `set -euo pipefail` (except `hetzner-watch.sh` which omits `-e` so polling loops survive failed checks; `_hook-env.sh` uses `set -uo pipefail` without `-e` for resilient hook execution)
- Hook scripts source `_hook-env.sh` which provides lazy JSON input reading via `hook_input()` / `hook_json()`, not raw `cat`
- ntfy notifications go to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()` helper with journald fallback
- All hook scripts log to journald via `logger -t "roost/<script-name>"`; query with `journalctl -t roost/health-check`, etc.
