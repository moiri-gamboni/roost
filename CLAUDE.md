# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Roost is a single deploy script that provisions and configures a Hetzner Cloud server for running Claude Code agents, web apps, and supporting infrastructure. The target is a hardened Ubuntu 24.04 server with btrfs snapshots, Tailscale (private networking), Cloudflare Tunnel (public web apps), and native systemd services.

## Commands

```bash
# Full provision/deploy from laptop (idempotent, safe to re-run)
./deploy.sh

# Verify server health over SSH
./test-server.sh

# On server: show what would change
roost-apply

# On server: deploy changed files and reload services
roost-apply push

# On server: deploy a specific file
roost-apply push files/hooks/notify.sh

# On server: reload specific services (flag mode)
roost-apply --caddy --cloudflare
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
| `ROOST_DIR_NAME` | no | Directory name under `~/` (default: `roost`) |
| `CLOUDFLARE_API_TOKEN` | yes | Needs Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit |
| `CLOUDFLARE_TUNNEL_NAME` | no | Defaults to `$ROOST_DIR_NAME` |
| `CLOUDFLARE_ACCOUNT_ID` | no | Skips account lookup if provided |
| `TAILSCALE_AUTHKEY` | yes | Pre-authenticated key for unattended setup |
| `TAILSCALE_API_KEY` | no | API key for setting ACL policy during deploy; manual setup if empty |
| `GITHUB_TOKEN_<owner>` | no | Fine-grained PATs for the server, one per GitHub owner (replace hyphens with underscores in variable name) |

## Script Roles

- **`deploy.sh`** -- Full provisioning and setup, run from your laptop. Sources `.env`, logs to `logs/` (gitignored). Idempotent and safe to re-run.
- **`roost-apply`** (`~/bin/` symlink to `hooks/roost-apply.sh`) -- Single tool for deploying config changes and reloading services. Subcommand mode (`diff`/`push`/`list`) handles manifest-based file deployment, `systemctl daemon-reload`, and batched service restarts. Flag mode (`--caddy`/`--cloudflare`/`--ntfy`/`--systemd`/`--cron`/`--all`) reloads specific services directly. Environment from `.sync-env`.

## Key Design Patterns

**Idempotency**: `deploy.sh` uses check-then-act for every section (`command -v`, `id -u`, `grep -q`, etc.) in the remote setup blocks. It is safe to re-run after partial failures or to apply changes.

**SSH helpers in deploy.sh**: `remote()` and `remote_tty()` run commands on the server. `remote_script()` runs a setup script from the deployed files directory. `remote_rescue()` handles rescue-mode SSH with relaxed host key checking.

**Shared environment via `files/_setup-env.sh`**: Sourced by every setup script. Reads `.env` values from the server copy, exports `USERNAME`, `HOME_DIR`, etc., and provides `as_user()` helper.

**Firewall model**: The Hetzner cloud firewall has a temporary SSH rule that exists only during deploys. `deploy.sh` adds it at the start and removes it at the end, so public SSH is locked out between deploys. UFW on the server allows SSH on port 22 (the cloud firewall controls whether traffic reaches it). Tailscale handles private access; Cloudflare Tunnel handles public web traffic. The only permanent public port is UDP 41641 (Tailscale WireGuard).

**Dual-stack networking**: IPv6 is **enabled** server-wide. Hetzner provides a /64; the server binds `::1` of the prefix on eth0. Every firewall rule you add must cover both stacks:
- `iptables ...` → add a matching `ip6tables ...` rule (same chain, same intent).
- `ip rule add ...` → add a matching `ip -6 rule add ...`.
- `ip route ...` in a named table → same for `ip -6 route ...`.
- `ufw allow ...` → UFW manages both stacks automatically when `IPV6=yes` in `/etc/default/ufw` (Ubuntu default).
- Hetzner cloud firewall rules added via `hcloud firewall add-rule` → pass **both** `--source-ips 0.0.0.0/0 --source-ips ::/0` so v6 traffic isn't silently dropped.
- Anything sysctl-related on `net.ipv4.conf.*` almost always needs the `net.ipv6.conf.*` counterpart (`rp_filter` is an exception — v6 doesn't have it).

Services that must stay **v4-only** pin their bind explicitly: Caddy via `default_bind $TAILSCALE_IP`, ntfy via `listen-http: "0.0.0.0:2586"`. New services that bind `:` or `::` will auto-pick-up v6 on dual-stack Linux — decide intentionally.

**`~/roost/` directory**: All managed state lives under `~/$ROOST_DIR_NAME/` (default `~/roost/`, configurable via `ROOST_DIR_NAME` in `.env`). `CLAUDE_CONFIG_DIR=~/$ROOST_DIR_NAME/claude` redirects Claude Code's config there.

## File Layout

- **`deploy.sh`** -- See Script Roles above
- **`files/`** -- Config files and templates deployed to the server
  - `_setup-env.sh` -- Shared environment sourced by every setup script
  - `settings.json` -- Claude Code settings with hook definitions (SessionStart/End, PreCompact, Stop, PreToolUse, Notification)
  - `private/` -- Separate git repo (`claude-mds`); commit changes there, then deploy with `roost-apply push`
    - `global-CLAUDE.md` -- Deployed to `$CLAUDE_CONFIG_DIR/CLAUDE.md` (`~/roost/claude/CLAUDE.md`); epistemic style, learning system, memory format
    - `code-CLAUDE.md` -- Deployed to `~/roost/code/CLAUDE.md`; safety, planning, search, agent, and tool conventions
  - `Caddyfile` -- Caddy reverse proxy config template (envsubst-expanded); imports `/etc/caddy/sites-enabled/*` for app routes
  - `caddy-tailscale.conf` -- Systemd drop-in for Caddy to wait for Tailscale
  - `cloudflare-config.yml` -- Cloudflare Tunnel base config template (envsubst-expanded); app ingress via fragments
  - `ntfy-server.yml` -- ntfy server configuration
  - `tailscaled-iptables.conf` -- Systemd drop-in pinning `tailscaled` to the iptables firewall backend (so travel-vpn's masked fwmark has predictable Tailscale mark bits to work around)
  - `tmux.conf` -- Tmux configuration deployed to server
  - `btrfs-convert.sh` -- Rescue-mode script to convert ext4 to btrfs with @rootfs subvolume
  - `glances.service` -- Systemd unit for Glances monitoring
  - `ram-monitor.service` / `ram-monitor.timer` -- Systemd units for per-process RAM alerting (30s interval)
  - `cron-roost` -- Crontab entries for health checks, scheduled tasks, auto-update
  - `bashrc-append.sh` -- Stub appended to `~/.bashrc`; sources `~/.bashrc.d/$ROOST_DIR_NAME.sh`
  - `profile-append.sh` -- Stub appended to `~/.profile`; sources the same file for non-interactive shells
  - `shell/bashrc.sh` -- Shell configuration (PATH, tmux, agent helpers); deployed to `~/.bashrc.d/roost.sh`
  - `hooks/` -- Shell scripts for Claude Code hooks and cron jobs
    - `_hook-env.sh` -- Shared library: JSON input parsing (`hook_json`), ntfy helpers, rate limiting, logging
    - `reflect.md` -- Prompt injected by `reflect.sh` before context compaction
    - `roost-apply.sh` -- Config deployment and service reload (manifest-based + flag mode)
    - `roost-net.sh` -- Travel VPN control CLI: `status`, `travel on/off`, `vpn on/off`, `test`, `client {android|laptop|ssh}`, `rotate-keys`; symlinked as `~/bin/roost-net`
    - `cloudflare-assemble.sh` -- Assembles cloudflare config from base header + app fragments
  - `skills/` -- Claude Code skills deployed to `$CLAUDE_CONFIG_DIR/skills/`
    - `html2markdown/SKILL.md`, `havelock-api/SKILL.md`
  - `sshd/` -- sshd drop-in configs (`50-clip-forward.conf`: `StreamLocalBindUnlink yes`)
  - `travel/` -- Travel VPN server pieces (Xray + Proton egress); see Travel VPN section below
    - `xray.service`, `xray-boot-guard`, `xray-logrotate.conf`, `xray-config.json.tmpl` -- Xray runtime
    - `keys-init.sh` -- Generates `/etc/roost-travel/state.env` (REALITY keypair, UUID, SS-2022 password, shortIds)
    - `proton-routing.sh` -- wg-quick PostUp/PreDown: dual-stack fwmark policy routing + kill-switch. Also supports `ensure` (idempotent re-apply of ip rules + proton-table route) for self-heal.
    - `proton-keepalive.service` / `.timer` / `proton-keepalive-check` -- Debounced watchdog (30s)
    - `proton-routing-ensure.service` / `.timer` -- Self-heal: `proton-routing.sh ensure` runs every 5m. Catches ip-rule flushes from systemd re-exec etc. that iptables survives but ip rules don't.
    - `apt-roost-travel.conf` -- Dpkg `Post-Invoke` hook deployed to `/etc/apt/apt.conf.d/99-roost-travel.conf`. Runs `proton-routing.sh ensure` after every dpkg op so unattended-upgrades re-execs don't leave a 5m outage window.
    - `wg-proton.service.d/roost.conf` -- Drop-in for `wg-quick@wg-proton` (ordering + kill-switch sanity)
    - `proton.conf.example` -- Template for Proton WG configs; drop per-profile copies under `/etc/roost-travel/proton-profiles/<name>.conf`
    - `travel-health.sh` -- Deployed as `health-check-apps.sh`; sourced by the base health check
    - `travel-cloudflare.yml.tmpl` -- CF Tunnel ingress fragment (copied to `~/roost/cloudflared/apps/travel.yml` by `roost-net travel on`)
  - `setup/` -- Modular setup scripts, run via `remote_script()` in deploy.sh: `system`, `create-user`, `ssh-hardening`, `ufw`, `swap`, `snapper` (btrfs), `tailscale`, `shell-config`, `dev-tools`, `caddy`, `ntfy`, `cloudflare`, `travel-vpn`, `ollama`, `glances`, `ram-monitor`, `cron`, `claude-code`, `claude-config`, `agent-tools`, `et`, `clip-forward`, `unattended-upgrades`
  - `laptop/` -- Scripts and systemd units designed to run on the laptop, not the server. Each component has a self-contained `install-*.sh` that reads `.env` and handles install + unit rendering + enable in one step.
    - `btrfs-backup.sh` + `roost-backup.service` / `roost-backup.timer` + `install-btrfs-backup.sh` -- Pull-based incremental btrfs snapshot backup (`btrfs send`/`receive`). Daily timer (`RandomizedDelaySec=1h`, `Persistent=true`).
    - `drop-watch.sh` + `drop-watch.service` + `install-drop-watch.sh` -- inotifywait-based folder watcher; auto-rsyncs `~/drop/` to server on change. Installed as a systemd *user* service (not system-wide) so it has the user's SSH keys.
    - `clip-forward.service` -- Clipboard forwarding daemon (image paste over SSH)
    - `gh-ruleset-sync.sh` + `gh-ruleset-sync.service` / `gh-ruleset-sync.timer` + `install-gh-ruleset-sync.sh` -- Periodic sync of the "Protect main" ruleset across all repos owned by the authenticated gh user; closes the gap between `./deploy.sh` runs. Daily + 2h jitter, `Persistent=true`.
    - `protect-main.ruleset.json` -- Canonical ruleset body shared between `deploy.sh` initial provision and the timer (single source of truth)
    - `roost-net-fw.sh` -- Open/close the Hetzner cloud firewall ports (443/tcp, 51820/tcp+udp) during travel
    - `travel-clients.sh` -- SSHes to server, calls `roost-net client <mode>`, prints to stdout or writes to `--save PATH` or ships to a Tailscale peer via `--send-tailscale PEER`
    - `travel-test.sh` -- End-to-end sanity checks for all three paths; `--simulate-gfw` blocks UDP locally to verify TCP-only paths still work; `--tailscale-check` validates exit-node routing
    - `roost-travel.sh` + `roost-travel.service` + `install-travel.sh` -- Laptop-side sing-box tunnel. `install-travel.sh` is a one-shot installer (sing-box CLI + wrapper + systemd unit + config fetch). Usage: `roost-travel {on|off|status|logs|config}`; `on`/`off` toggle both running state and enabled state (persistence across reboot).
- **`extras/`** -- Standalone utilities not part of the main setup flow
  - `hetzner-watch.sh` -- Polls Hetzner API for server type availability, sends ntfy alerts
- **`test-server.sh`** -- Server verification script; tests services over SSH, logs to `logs/`

## Server Directory Structure

The directory name `roost` is configurable via `ROOST_DIR_NAME` in `.env`.

```
~/roost/                    Managed root directory
├── claude/                 Claude Code config (CLAUDE_CONFIG_DIR)
│   ├── settings.json       Hooks, cleanup policy
│   ├── hooks/              Hook scripts + utilities (roost-apply, cloudflare-assemble)
│   ├── skills/             Skills
│   ├── locks/              Session lock files
│   └── projects/           Session transcripts (auto-managed)
├── cloudflared/            Cloudflare Tunnel fragments
│   └── apps/               Per-app ingress YAML fragments
├── memory/                 Structured notes (grepai-indexed)
└── code/                   Project repositories
    └── CLAUDE.md           Code conventions (auto-discovered by all projects)

~/.bashrc.d/
└── roost.sh                Shell configuration (PATH, tmux, agent helpers)
```

## Hook Architecture

Hooks are defined in `files/settings.json` and deployed to `~/roost/claude/hooks/`:

| Hook Event | Script | Purpose |
|---|---|---|
| SessionStart | `session-lock.sh` | Writes a lock file with hostname/tmux/PID metadata for multi-machine coordination |
| SessionEnd | `session-unlock.sh` | Removes the lock file; auto-names unnamed sessions via `claude -p --model sonnet` (background) |
| PreCompact | `reflect.sh` | Injects a prompt reminding the agent to save learnings before context compaction |
| Notification | `notify.sh` | Sends push notifications via local ntfy (with rate limiting and priority levels) |

Hook scripts source `_hook-env.sh` (except `reflect.sh` which just cats a prompt file) which provides `hook_json()` for parsing Claude Code's JSON input, `ntfy_send()` for notifications (with journald fallback), `rate_limit_ok()` to prevent notification floods, and journald logging via `logger -t "$_HOOK_TAG"` (tags: `roost/<script-name>`).

Cron-triggered hooks (not Claude Code events):
- `health-check.sh` -- Checks Ollama, Caddy, ntfy, Tailscale, cloudflared, disk; hard failures bundle into a high-priority `Service health alert`, cooled down by failure-set hash (notify on set change, else at most hourly). Soft signals (sustained swap >3GB high-priority, pending reboot via `/var/run/reboot-required` default-priority) send their own ntfy with per-event cooldowns (swap: 1h; reboot: 7d reminder, re-arms on new mtime). Sources `health-check-apps.sh` if present for app-specific checks.
- `scheduled-task.sh` / `run-scheduled-task.sh` -- Runs Claude Code tasks in tmux windows. Two configured: daily 8:00 morning summary (ntfy history), Sunday 10:00 memory cleanup (deduplicates `~/roost/memory/`). Both run as headless `claude -p` in a `cron` tmux session.
- `auto-update.sh` -- Weekly updates (Sunday 3am) with btrfs snapshot before, ntfy summary after. Safeguards: 7-day release cooldown, major version guard (blocked and reported via ntfy). Updated tools: Claude Code, claude-code-tools, aichat-search, claude-code-transcripts, Go, fnm, Node.js LTS, uv, Ollama models, grepai, gitleaks, rodney, OS packages. Logs: `journalctl -t roost/auto-update`.

Systemd timer (not cron):
- `ram-monitor.sh` -- Alerts when any process exceeds 3GB RSS (runs every 30s via `ram-monitor.timer`, tracks notified PIDs to avoid repeats)

Server-side utilities (manually triggered, not hooks):
- `roost-apply.sh` -- Config deployment and service reload. Subcommand mode (`diff`/`push`/`list`) deploys files from the repo manifest; flag mode (`--caddy`/`--cloudflare`/etc.) reloads specific services. Aliased as `roost-apply` in bashrc.
- `cloudflare-assemble.sh` -- Assembles `/etc/cloudflared/config.yml` from base tunnel header + per-app fragments in `~/roost/cloudflared/apps/*.yml`

## Native Services

All infrastructure runs as native systemd services installed via official apt repos:
- **Caddy** (`caddy.service`) -- Reverse proxy bound to Tailscale IP via `default_bind` in Caddyfile. Config at `/etc/caddy/Caddyfile`.
- **cloudflared** (`cloudflared.service`) -- Cloudflare Tunnel. Config at `/etc/cloudflared/config.yml`.
- **ntfy** (`ntfy.service`) -- Push notifications on `0.0.0.0:2586` (auth required, firewall limits to localhost + Tailscale). Config at `/etc/ntfy/server.yml`.

Caddy has a systemd drop-in that waits for Tailscale before starting. Updates are handled by `apt upgrade` (via auto-update.sh and unattended-upgrades).

## Travel VPN

Toggleable GFW-resistant network with a Proton egress layer. See `plans/travel-vpn-architecture.md` for full design rationale. High-level:

**Paths:** three concurrent Xray inbounds on the server, sing-box urltest on clients picks the fastest:
- **Path A** -- VLESS + WebSocket + TLS behind the existing Cloudflare Tunnel (CF terminates TLS, xray listens on `127.0.0.1:10000`).
- **Path B** -- VLESS + gRPC + REALITY on `:::443` direct to Hetzner (masquerades as `www.samsung.com`).
- **Path C** -- Shadowsocks-2022 (`chacha20-poly1305`) on `:::51820` direct to Hetzner, TCP + UDP.

**Egress:** optional ProtonVPN WireGuard (`wg-proton`) as a policy-routed outbound. Traffic from the `xray` system user plus Tailscale-exit-node forwarded traffic gets fwmarked with `0x1337` (mask `0x0000ffff`, so Tailscale's own mark bits survive). A dual-stack kill-switch REJECTs anything from those sources that would otherwise leak out `eth0`.

**Toggles (four modes, two state files in `/etc/roost-travel/`):**

| Mode | Phone transport | `roost-net travel` | `roost-net vpn` | Phone egress |
|---|---|---|---|---|
| Home, normal | ISP direct | off | off | ISP |
| Home, private | Tailscale exit node | off | on | Proton |
| Travel | Xray A/B/C | on | off | Hetzner |
| Travel, private | Xray A/B/C | on | on | Proton |

**State:** `/etc/roost-travel/{travel,vpn}` contain `on`/`off`. `/etc/roost-travel/state.env` (`0600 root`) holds the generated keys (UUID, REALITY keypair, shortIds, SS-2022 password). `vpn=on` is persisted via `systemctl enable --now wg-quick@wg-proton` so the server survives an in-country update + reboot.

**Server CLI (`roost-net`):**
- `roost-net status` -- current toggles, egress IP, service status
- `roost-net travel on|off` -- deploy/remove CF fragment, open/close UFW for 443/tcp + 51820/tcp+udp
- `roost-net vpn on|off` -- enable/disable `wg-quick@wg-proton` + keepalive timer, verify egress is external (not our Hetzner IP) on activation
- `roost-net vpn profile [name]` -- list/activate Proton profiles under `/etc/roost-travel/proton-profiles/*.conf` (e.g. NetShield-on vs NetShield-off); swaps `/etc/wireguard/wg-proton.conf` symlink and hot-restarts wg-quick if vpn=on
- `roost-net test` -- plan §4.2 assertions (fwmark masking, kill-switch REJECT, external egress)
- `roost-net client {android|laptop|ssh}` -- emit sing-box or SSH config from `state.env`
- `roost-net rotate-keys` -- regenerate `state.env` via `keys-init.sh --force`, restart Xray

**Laptop CLI (`files/laptop/roost-net-fw.sh`):** opens/closes the Hetzner cloud firewall for travel ports (dual-stack). `SERVER_NAME-fw` is the firewall name convention from `deploy.sh`.

**Operational playbook:** pre-departure, travel, mid-flight degradation handling -- see README + `plans/travel-vpn-architecture.md` §6.

## App-Specific Extensions

The base infrastructure configs are generic and stay in the repo. Server-specific app configs go in dedicated locations that the base configs import/source, avoiding divergence:

| What | Where | Notes |
|---|---|---|
| Caddy app routes | `/etc/caddy/sites-enabled/<app>.caddy` | Imported by Caddyfile via `import /etc/caddy/sites-enabled/*` |
| Caddy Tailscale-only apps | `/etc/caddy/apps-enabled/<app>.caddy` | Per-app `handle_path` fragments imported by `sites-enabled/apps.caddy` (see below) |
| Cloudflare ingress | `~/roost/cloudflared/apps/<app>.yml` | Assembled by `cloudflare-assemble.sh`; each file contains ingress rule lines |
| App cron jobs | `/etc/cron.d/${ROOST_DIR_NAME}-apps` | Separate file from the base cron; filenames must not contain dots |
| App health checks | `~/roost/claude/hooks/health-check-apps.sh` | Sourced by `health-check.sh` if present; uses same `check()` and `check_service()` helpers. Currently occupied by travel-vpn (`files/travel/travel-health.sh` deploys to that path); append additional app-specific checks rather than overwrite. |

### Tailscale-Only Static Apps

Internal apps share `:8090` with path-based routing. `sites-enabled/apps.caddy` imports per-app `handle_path` fragments from `/etc/caddy/apps-enabled/*.caddy`. To add an app: drop a `.caddy` file in `apps-enabled/` with a `handle_path /<name>/* { root * /path/to/files; file_server }` block, then reload Caddy. Access at `http://<tailscale-ip>:8090/<name>/`. Ensure files are world-readable for the `caddy` user.

## Shell Helpers

Agent management functions (defined in `files/shell/bashrc.sh`, deployed to `~/.bashrc.d/roost.sh`):

| Command | Usage |
|---|---|
| `agent [path] [claude-args...]` | Launch interactive Claude in a tmux window (path defaults to cwd); resolves `GH_TOKEN` from `~/.config/git/tokens/<owner>` based on the repo's git remote |
| `agent -c` | Continue last session in cwd |
| `agents` | Interactive tmux window picker |
| `agent_stop <index>` | Graceful stop (Ctrl-D, triggers SessionEnd hooks) |
| `agent_kill <index>` | Force stop (double Ctrl-C) |

Using `/rename` inside a session updates the tmux window name automatically.

## roost-apply Usage

Runs on the server. Aliased as `roost-apply` in bashrc.

**Subcommand mode** (manifest-based file deployment):

```bash
roost-apply                             # Show diff of all changed files (default)
roost-apply diff                        # Same as above
roost-apply diff files/hooks/notify.sh  # Diff a specific file
roost-apply push                        # Deploy all changed files and reload services
roost-apply push files/ram-monitor.timer  # Deploy a specific file
roost-apply push -y                     # Skip confirmation prompt
roost-apply list                        # List all managed files in the manifest
```

**Flag mode** (direct service reload, for app-specific configs not in the manifest):

```bash
roost-apply --all            # Reload everything
roost-apply --caddy          # Reload Caddy only
roost-apply --cloudflare     # Assemble fragments and restart cloudflared
roost-apply --ntfy           # Restart ntfy
roost-apply --systemd        # Daemon-reload + restart changed systemd units
roost-apply --cron           # Reinstall crontab
roost-apply --xray           # Re-render /etc/xray/config.json from state.env and restart xray
roost-apply --proton         # Daemon-reload; restart proton-keepalive.timer + proton-routing-ensure.timer + wg-quick@wg-proton (skipped when vpn=off)
```

## Recovery

| Layer | Tool | Granularity |
|---|---|---|
| Full filesystem | btrfs snapshots (snapper) | Hourly |
| Off-site backup | btrfs send/receive to laptop (`files/laptop/btrfs-backup.sh`) | Daily |
| Disaster recovery | Hetzner backups | Daily |

Snapper retention: 24 hourly, 7 daily, 4 weekly. Rollback: `snapper list`, then `snapper rollback <number>`, then reboot.

## Security Model

**Tailscale ACLs**: The server is registered with `tag:server`. ACLs allow laptop/phone to reach the server but block the server from initiating connections to other devices. This limits blast radius if a prompt injection compromises a Claude session. When `TAILSCALE_API_KEY` is set in `.env`, `deploy.sh` sets the restrictive ACL policy automatically via the Tailscale API.

**GitHub credentials**: Fine-grained PATs scoped to "Contents: Read and write" (plus other low-risk permissions) but explicitly excluding Administration, Workflows, Webhooks, Secrets, and Codespaces. This prevents a compromised session from modifying branch rulesets, injecting CI secrets, or exfiltrating code via webhooks. When `GITHUB_TOKEN_*` variables are set in `.env`, `deploy.sh` stores tokens on the server, authenticates `gh`, and configures git for HTTPS. Branch rulesets (block deletion and force push on main) are created automatically on personal repos when `gh` is installed and authenticated on the laptop.

## Shell Conventions

- All scripts use `set -euo pipefail` (except `hetzner-watch.sh` which omits `-e` so polling loops survive failed checks; `_hook-env.sh` uses `set -uo pipefail` without `-e` for resilient hook execution)
- Hook scripts source `_hook-env.sh` which provides lazy JSON input reading via `hook_input()` / `hook_json()`, not raw `cat`
- ntfy notifications go to `http://localhost:2586/claude-$(whoami)` via `ntfy_send()` helper with journald fallback
- All hook scripts log to journald via `logger -t "roost/<script-name>"`; query with `journalctl -t roost/health-check`, etc.
