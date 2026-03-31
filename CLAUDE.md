# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure. The target is a hardened Ubuntu 24.04 server with btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), and native systemd services.

## Commands

```bash
# Full provision/deploy from laptop (idempotent, safe to re-run)
./deploy.sh

# Lightweight file sync (push local changes to server)
./sync.sh push

# Lightweight file sync (pull server changes, shows diff for envsubst files)
./sync.sh pull

# Verify server health over SSH
./test-server.sh

# On server: apply config changes (checksum-based reload)
roost-apply
```

## Environment Variables

Configured in `.env` (copy from `.env.example`). Hetzner API token is stored by `hcloud context create roost`, not in `.env`.

| Variable | Required | Description |
|---|---|---|
| `SERVER_NAME` | yes | Hetzner server name |
| `SERVER_TYPE` | yes | Hetzner server type (e.g. `cx43`) |
| `SERVER_LOCATION` | no | Comma-separated location preference list (e.g. `nbg1,fsn1`); empty = auto |
| `SSH_KEY_NAME` | no | Hetzner SSH key name; interactive prompt if empty |
| `USERNAME` | yes | Non-root user created on the server |
| `DOMAIN` | yes | Domain managed in Cloudflare |
| `ROOST_DIR_NAME` | no | Synced directory name under `~/` (default: `roost`) |
| `CLOUDFLARE_API_TOKEN` | yes | Needs Account > Tunnel > Edit and Zone > DNS > Edit |
| `CLOUDFLARE_TUNNEL_NAME` | no | Defaults to `$ROOST_DIR_NAME` |
| `CLOUDFLARE_ACCOUNT_ID` | no | Skips account lookup if provided |
| `TAILSCALE_AUTHKEY` | yes | Pre-authenticated key for unattended setup |

## Script Roles

- **`deploy.sh`** -- Full provisioning and setup, run from your laptop. Sources `.env`, logs to `logs/` (gitignored). Idempotent and safe to re-run.
- **`sync.sh`** -- Lightweight file sync between repo and server over Tailscale SSH. Manages `chattr +i` flags, groups `systemctl daemon-reload`, and batches service restarts. Pull cannot reverse `envsubst` files (shows diff instead).
- **`roost-apply`** (server-side alias) -- Detects config changes via checksum comparison, reloads only affected services. Checksums stored in `~/.cache/roost-apply/checksums`.

## Key Design Patterns

**Idempotency**: `deploy.sh` uses check-then-act for every section (`command -v`, `id -u`, `grep -q`, etc.) in the remote setup blocks. It is safe to re-run after partial failures or to apply changes.

**SSH helpers in deploy.sh**: `remote()` and `remote_tty()` run commands on the server. `remote_script()` runs a setup script from the deployed files directory. `remote_rescue()` handles rescue-mode SSH with relaxed host key checking.

**Shared environment via `files/_setup-env.sh`**: Sourced by every setup script. Reads `.env` values from the server copy, exports `USERNAME`, `HOME_DIR`, etc., and provides `as_user()` helper.

**Firewall model**: The Hetzner cloud firewall has a temporary SSH rule that exists only during deploys. `deploy.sh` adds it at the start and removes it at the end, so public SSH is locked out between deploys. UFW on the server allows SSH on port 22 (the cloud firewall controls whether traffic reaches it). Tailscale handles private access; Cloudflare Tunnel handles public web traffic. The only permanent public port is UDP 41641 (Tailscale WireGuard).

**`~/roost/` directory**: All synced state lives under `~/$ROOST_DIR_NAME/` (default `~/roost/`, configurable via `ROOST_DIR_NAME` in `.env`), making Syncthing configuration a single folder share. `CLAUDE_CONFIG_DIR=~/$ROOST_DIR_NAME/claude` redirects Claude Code's config there.

## File Layout

- **`deploy.sh`** / **`sync.sh`** -- See Script Roles above
- **`files/`** -- Config files and templates deployed to the server
  - `_setup-env.sh` -- Shared environment sourced by every setup script
  - `settings.json` -- Claude Code settings with hook definitions (SessionStart/End, PreCompact, Stop, PreToolUse, Notification)
  - `private/` -- Gitignored; clone your private `claude-mds` repo here for personal CLAUDE.md files
    - `global-CLAUDE.md` -- Deployed to `~/.claude/CLAUDE.md`; epistemic style, learning system, memory format
    - `code-CLAUDE.md` -- Deployed to `~/roost/code/CLAUDE.md`; safety, planning, search, agent, and tool conventions
  - `Caddyfile` -- Caddy reverse proxy config template (envsubst-expanded); imports `/etc/caddy/sites-enabled/*` for app routes
  - `caddy-tailscale.conf` -- Systemd drop-in for Caddy to wait for Tailscale
  - `cloudflare-config.yml` -- Cloudflare Tunnel base config template (envsubst-expanded); app ingress via fragments
  - `ntfy-server.yml` -- ntfy server configuration
  - `syncthing-tailscale.conf` -- Systemd drop-in for Syncthing to wait for Tailscale
  - `tmux.conf` -- Tmux configuration deployed to server
  - `btrfs-convert.sh` -- Rescue-mode script to convert ext4 to btrfs with @rootfs subvolume
  - `glances.service` -- Systemd unit for Glances monitoring
  - `ram-monitor.service` / `ram-monitor.timer` -- Systemd units for per-process RAM alerting (30s interval)
  - `cron-roost` -- Crontab entries for health checks, scheduled tasks, auto-update
  - `bashrc-append.sh` -- Stable 2-line stub appended to `~/.bashrc`; sources `~/roost/shell/bashrc.sh`
  - `shell/bashrc.sh` -- Shell configuration (PATH, tmux, agent helpers); deployed to `~/roost/shell/`
  - `hooks/` -- Shell scripts for Claude Code hooks and cron jobs
    - `_hook-env.sh` -- Shared library: JSON input parsing (`hook_json`), ntfy helpers, rate limiting, logging
    - `reflect.md` -- Prompt injected by `reflect.sh` before context compaction
    - `dangerous-command-blocker.py` -- PreToolUse hook blocking destructive commands (vendored from claude-code-templates, MIT)
    - `roost-apply.sh` -- Server-side service reload with checksum-based change detection
    - `cloudflare-assemble.sh` -- Assembles cloudflare config from base header + app fragments
  - `setup/` -- Modular setup scripts, run via `remote_script()` in deploy.sh: `system`, `create-user`, `ssh-hardening`, `ufw`, `ipv6-disable`, `swap`, `snapper` (btrfs), `tailscale`, `shell-config`, `dev-tools`, `caddy`, `ntfy`, `syncthing`, `cloudflare`, `ollama`, `glances`, `ram-monitor`, `cron`, `claude-code`, `claude-config`, `agent-tools`, `harden-hooks`, `unattended-upgrades`
- **`extras/`** -- Standalone utilities not part of the main setup flow
  - `hetzner-watch.sh` -- Polls Hetzner API for server type availability, sends ntfy alerts
- **`test-server.sh`** -- Server verification script; tests services over SSH, logs to `logs/`

## Server Directory Structure

The directory name `roost` is configurable via `ROOST_DIR_NAME` in `.env`.

```
~/roost/                    Syncthing-synced root
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts + utilities (roost-apply, cloudflare-assemble)
│   ├── skills/             Skills
│   ├── locks/              Session lock files
│   └── projects/           Session transcripts (auto-managed)
├── shell/                  Shell configuration (bashrc.sh)
├── cloudflared/            Cloudflare Tunnel fragments
│   └── apps/               Per-app ingress YAML fragments
├── memory/                 Structured notes (grepai-indexed)
└── code/                   Project repositories
    └── CLAUDE.md           Code conventions (auto-discovered by all projects)
```

## Hook Architecture

Hooks are defined in `files/settings.json` and deployed to `~/roost/claude/hooks/`:

| Hook Event | Script | Purpose |
|---|---|---|
| SessionStart | `session-lock.sh` | Writes a lock file with hostname/tmux/PID metadata for multi-machine coordination |
| SessionEnd | `session-unlock.sh` | Removes the lock file; auto-names unnamed sessions via `claude -p --model sonnet` (background) |
| PreCompact | `reflect.sh` | Injects a prompt reminding the agent to save learnings before context compaction |
| Stop | `auto-commit.sh` | Stages tracked + new files, runs gitleaks, commits with session ID |
| PreToolUse | `dangerous-command-blocker.py` | Blocks catastrophic commands (rm -rf /, dd), protects critical paths (.git, .env), warns on suspicious patterns |
| Notification | `notify.sh` | Sends push notifications via local ntfy (with rate limiting and priority levels) |

All hook scripts source `_hook-env.sh` which provides `hook_json()` for parsing Claude Code's JSON input, `ntfy_send()` for notifications (with journald fallback), `rate_limit_ok()` to prevent notification floods, and journald logging via `logger -t "$_HOOK_TAG"` (tags: `roost/<script-name>`).

Cron-triggered hooks (not Claude Code events):
- `health-check.sh` -- Checks Ollama, Caddy, ntfy, Syncthing, Tailscale, cloudflared, disk, inodes, swap; alerts via ntfy. Sources `health-check-apps.sh` if present for app-specific checks.
- `scheduled-task.sh` / `run-scheduled-task.sh` -- Runs Claude Code tasks in tmux windows
- `auto-update.sh` -- Weekly updates with btrfs snapshot before, ntfy summary after (7-day cooldown, major version guard)
- `conflict-check.sh` -- Detects Syncthing conflict files in `~/roost/`, alerts via ntfy

Systemd timer (not cron):
- `ram-monitor.sh` -- Alerts when any process exceeds 3GB RSS (runs every 30s via `ram-monitor.timer`, tracks notified PIDs to avoid repeats)

Server-side utilities (manually triggered, not hooks):
- `roost-apply.sh` -- Detects config file changes via checksum comparison, reloads only affected services. Aliased as `roost-apply` in bashrc.
- `cloudflare-assemble.sh` -- Assembles `/etc/cloudflared/config.yml` from base tunnel header + per-app fragments in `~/roost/cloudflared/apps/*.yml`

## Native Services

All infrastructure runs as native systemd services installed via official apt repos:
- **Caddy** (`caddy.service`) -- Reverse proxy bound to Tailscale IP via `default_bind` in Caddyfile. Config at `/etc/caddy/Caddyfile`.
- **cloudflared** (`cloudflared.service`) -- Cloudflare Tunnel. Config at `/etc/cloudflared/config.yml`.
- **ntfy** (`ntfy.service`) -- Push notifications on `0.0.0.0:2586` (auth required, firewall limits to localhost + Tailscale). Config at `/etc/ntfy/server.yml`.
- **Syncthing** (`syncthing@$USERNAME.service`) -- File sync for `~/roost/`. GUI on `localhost:8384`, sync on Tailscale IP port 22000.

Caddy and Syncthing have systemd drop-ins that wait for Tailscale before starting. Updates are handled by `apt upgrade` (via auto-update.sh and unattended-upgrades).

The `dangerous-command-blocker` PreToolUse hook is vendored from [claude-code-templates](https://github.com/davila7/claude-code-templates) (MIT license). `harden-hooks.sh` sets `chattr +i` on hook scripts and settings to protect against Syncthing tampering; `deploy.sh` and `sync.sh` strip the flag before redeploying.

## App-Specific Extensions

The base infrastructure configs are generic and stay in the repo. Server-specific app configs go in dedicated locations that the base configs import/source, avoiding divergence:

| What | Where | Notes |
|---|---|---|
| Caddy app routes | `/etc/caddy/sites-enabled/<app>.caddy` | Imported by Caddyfile via `import /etc/caddy/sites-enabled/*` |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` | Assembled by `cloudflare-assemble.sh`; each file contains ingress rule lines |
| App cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` | Separate file from the base cron; filenames must not contain dots |
| App health checks | `~/roost/claude/hooks/health-check-apps.sh` | Sourced by `health-check.sh` if present; uses same `check()` and `check_service()` helpers |

## Shell Helpers

Agent management functions (defined in `files/shell/bashrc.sh`, available on the server):

| Command | Usage |
|---|---|
| `agent [path] [claude-args...]` | Launch interactive Claude in a tmux window (path defaults to cwd) |
| `agent -c` | Continue last session in cwd |
| `agents` | Interactive tmux window picker |
| `agent_stop <index>` | Graceful stop (Ctrl-D, triggers SessionEnd hooks including auto-commit) |
| `agent_kill <index>` | Force stop (double Ctrl-C) |

Using `/rename` inside a session updates the tmux window name automatically.

## sync.sh Usage

Works from both the laptop (over Tailscale SSH) and the server (local mode, auto-detected by hostname).

```bash
./sync.sh diff                          # Show all differences
./sync.sh diff files/hooks/notify.sh    # Diff a specific file
./sync.sh push                          # Push all changed files to server
./sync.sh push files/ram-monitor.timer  # Push a specific file
./sync.sh pull                          # Pull server changes to repo
./sync.sh list                          # List all managed files
```

Push shows a diff preview and asks for confirmation (skip with `--yes`/`-y`). Pull cannot reverse `envsubst` files (shows diff instead).

## roost-apply Usage

```bash
roost-apply                  # Auto-detect changes, reload affected services
roost-apply --all            # Reload everything
roost-apply --caddy          # Reload Caddy only
roost-apply --cloudflare     # Assemble fragments and restart cloudflared
roost-apply --systemd        # Daemon-reload + restart changed systemd units
```

## Recovery

| Layer | Tool | Granularity |
|---|---|---|
| Code changes | Git auto-commits (Stop hook) | Per agent turn |
| Full filesystem | btrfs snapshots (snapper) | Every 30 min |
| Disaster recovery | Hetzner backups | Daily |

Snapper retention: 24 hourly, 7 daily, 4 weekly. Rollback: `snapper list`, then `snapper rollback <number>`, then reboot.

## Shell Conventions

- All scripts use `set -euo pipefail` (except `hetzner-watch.sh` which omits `-e` so polling loops survive failed checks; `_hook-env.sh` uses `set -uo pipefail` without `-e` for resilient hook execution)
- Hook scripts source `_hook-env.sh` which provides lazy JSON input reading via `hook_input()` / `hook_json()`, not raw `cat`
- ntfy notifications go to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()` helper with journald fallback
- All hook scripts log to journald via `logger -t "roost/<script-name>"`; query with `journalctl -t roost/health-check`, etc.
